/*************************************************************************
 * Copyright (c) 2015-2016, NVIDIA CORPORATION. All rights reserved.
 *
 * See LICENSE.txt for license information
 ************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include "core.h"
#include "libwrap.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sched.h>
#include <fcntl.h>
#include <unistd.h>
#include <cuda_runtime.h>
#include <string.h>
#include <errno.h>

DebugLevel ncclDebugLevel;
int ncclPrintCRCs;

NCCL_API(ncclResult_t, ncclGetUniqueId, ncclUniqueId* out);
ncclResult_t ncclGetUniqueId(ncclUniqueId* out) {
  pid_t pid = getpid();
  static int count = 0;
  int commId = __sync_fetch_and_add(&count, 1);
  int len = snprintf(out->internal, NCCL_UNIQUE_ID_BYTES, "nccl-%d-%d", pid, commId);
  if(strlen(out->internal) < len) {
    WARN("ncclUniqueId truncated");
    return ncclInternalError;
  }
  return ncclSuccess;
}


static ncclResult_t shmOpen(const char* shmname, size_t bytes, void** ptr) {
  int fd = shm_open(shmname, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
  if (fd == -1) {
    WARN("shm_open failed to open %s", shmname);
    return ncclSystemError;
  }

  if (ftruncate(fd, bytes) == -1) {
    WARN("ftruncate failed to allocate %ld bytes", bytes);
    shm_unlink(shmname);
    close(fd);
    return ncclSystemError;
  }

  *ptr = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (*ptr == MAP_FAILED) {
    WARN("failure in mmap");
    shm_unlink(shmname);
    close(fd);
    return ncclSystemError;
  }

  close(fd);
  return ncclSuccess;
}

static ncclResult_t shmUnlink(const char* shmname) {
  if(shm_unlink(shmname) == -1) {
    WARN("smh_unlink failed");
    return ncclSystemError;
  } else {
    return ncclSuccess;
  }
}

static ncclResult_t shmUnmap(void* ptr, size_t bytes) {
  if(munmap(ptr, bytes) == -1) {
    WARN("munmap failed");
    return ncclSystemError;
  } else {
    return ncclSuccess;
  }
}


typedef struct {
  int rank;
  int ndev;
  int cudaDev;
  int sortId;
  pid_t pid;
  ncclMem* hostptr;
  ncclMem* devptr;
  cudaIpcMemHandle_t devipc;
  size_t buffSize;
} RankEntry;

static int compRanks(const void* a, const void* b) {
  const RankEntry* A = (const RankEntry*)a;
  const RankEntry* B = (const RankEntry*)b;
  if (A->sortId < B->sortId) return -1;
  if (A->sortId > B->sortId) return  1;
  return 0;
}

static void orderRanks(RankEntry* ranks, int count) {
  qsort(ranks, count, sizeof(RankEntry), compRanks);
}


typedef struct {
  union {
    struct {
      volatile int bar;
      int globalMemSpaceBroke;
    };
    char pad[16];
   };
   RankEntry ranks[1];
} RankGather;

static ncclResult_t initGather(RankGather** gather, ncclUniqueId commId,
    int ndev, int rank, RankEntry myInfo) {
  size_t bytes = offsetof(RankGather, ranks) + ndev*sizeof(RankEntry);
  RankGather* tmp = NULL;
  int bar_tmp;

  ncclResult_t res = shmOpen(commId.internal, bytes, (void**)&tmp);
  if (res != ncclSuccess) {
    WARN("rank %d failed to open shm segment for gather", rank);
    return res;
  }

  tmp->ranks[rank] = myInfo;

  bar_tmp = tmp->bar - 1;
  bool swapped;
  do {
    bar_tmp += 1;
    if (bar_tmp == ndev-1) { // everyone is done
      ncclResult_t res = shmUnlink(commId.internal);
      if (res != ncclSuccess) {
        WARN("rank %d failed to unlink shm segment for gather", rank);
        shmUnmap(tmp, bytes);
        return res;
      }

      orderRanks(tmp->ranks, ndev);
    }
    swapped = __sync_bool_compare_and_swap(&tmp->bar, bar_tmp, bar_tmp+1);
  } while(!swapped);

  while (tmp->bar < ndev)
    sched_yield();
  __sync_synchronize();

  *gather = tmp;
  return ncclSuccess;
}

static void syncRingDirect(RankGather* gather, int* globalMemSpaceOk) {
  int bar_tmp = gather->bar - 1;
  int ndev = gather->ranks[0].ndev;
  bool swapped;
  do {
    bar_tmp += 1;
    swapped = __sync_bool_compare_and_swap(&gather->bar, bar_tmp, bar_tmp+1);
  } while(!swapped);

  while (gather->bar < 2*ndev) // Wait for all ranks to arrive at this second barrier
    sched_yield();
  __sync_synchronize();

  *globalMemSpaceOk = gather->globalMemSpaceBroke ? 0 : 1;
}

static ncclResult_t closeGather(RankGather* gather, int ndev) {
  int bar_tmp = gather->bar - 1;
  bool swapped;
  do {
    bar_tmp += 1;
    swapped = __sync_bool_compare_and_swap(&gather->bar, bar_tmp, bar_tmp+1);
  } while(!swapped);

  while (gather->bar < 3*ndev) // Wait for all ranks to arrive at this third barrier
    sched_yield();
  __sync_synchronize();

  size_t bytes = offsetof(RankGather, ranks) + ndev*sizeof(RankEntry);
  ncclResult_t res = shmUnmap(gather, bytes);
  if (res != ncclSuccess) {
    WARN("failed to unmap %ld bytes of gather", bytes);
    return res;
  }

  return ncclSuccess;
}


static ncclResult_t allocDevMem(ncclMem** ptr, size_t buffSize) {
  size_t size = offsetof(struct ncclMem, buff) + buffSize;
  cudaError_t res = cudaMalloc((void**)ptr, size);
  if (res != cudaSuccess) {
    *ptr = NULL;
    WARN("failed to allocate %lu byte device buffer", size);
    return ncclCudaMallocFailed;
  }
  if (cudaMemset(*ptr, 0, size) != cudaSuccess) {
    WARN("failed to memset device buffer.");
    cudaFree(*ptr);
    *ptr = NULL;
    return ncclUnhandledCudaError;
  }
  return ncclSuccess;
}

static const int ShmMapped = 1;
static const int ShmLinked = 2;

static ncclResult_t allocHostMem(ncclMem** ptr, size_t buffSize) {
  size_t size = offsetof(struct ncclMem, buff) + buffSize;
  cudaError_t res = cudaMallocHost((void**)ptr, size);
  if (res != cudaSuccess) {
    *ptr = NULL;
    WARN("failed to allocate %lu byte host buffer", size);
    return ncclSystemError;
  }
  memset(*ptr, 0, size);
  return ncclSuccess;
}

static ncclResult_t openHostMemShm(const char* shmname, ncclMem** ptr, size_t buffSize) {
  size_t size = offsetof(struct ncclMem, buff) + buffSize;
  ncclResult_t res = shmOpen(shmname, size, (void**)ptr);
  if (res != ncclSuccess) {
    WARN("failed to allocate %lu byte shm buffer", size);
    *ptr = NULL;
    return res;
  }

  if(cudaHostRegister(*ptr, size, cudaHostRegisterMapped) != cudaSuccess) {
    WARN("failed to register host buffer");
    shmUnlink(shmname);
    shmUnmap(*ptr, size);
    *ptr = NULL;
    return ncclUnhandledCudaError;
  }
  return ncclSuccess;
}

static ncclResult_t populateRankInfo(RankEntry* info, int rank, ncclComm_t comm) {
  char busId[13];
  nvmlDevice_t nvmlHandle;
  cudaError_t res = cudaDeviceGetPCIBusId(busId, 13, comm->cudaDev);
  if (res == cudaErrorInvalidDevice) {
    WARN("rank %d attempted to access an invalid cuda device %d", rank, comm->cudaDev);
    return ncclInvalidDeviceIndex;
  } else if (res != cudaSuccess) {
    WARN("rank %d failed to get PCI Bus Id for device %d", rank, comm->cudaDev);
    return ncclUnhandledCudaError;
  }
  INFO("rank %d using device %d (%s)", rank, comm->cudaDev, busId);

  if (wrapNvmlDeviceGetHandleByPciBusId(busId, &nvmlHandle) != ncclSuccess) {
    WARN("rank %d failed to get nvml handle for device %s", rank, busId);
    return ncclUnhandledCudaError;
  }
  // Order by nvml index
  if (wrapNvmlDeviceGetIndex(nvmlHandle, (unsigned*)&info->sortId) != ncclSuccess) {
    WARN("rank %d failed to get nvml device index for device %d", rank, comm->cudaDev);
    return ncclUnhandledCudaError;
  }

  info->rank = rank;
  info->ndev = comm->nRanks;
  info->cudaDev = comm->cudaDev;
  info->pid = getpid();
  info->buffSize = comm->buffSize;
  info->hostptr = comm->hostMem;
  info->devptr = comm->devMem;
  if (cudaIpcGetMemHandle(&info->devipc, (void*)comm->devMem) != cudaSuccess) {
    WARN("rank %d failed to open CUDA IPC handle", rank);
    return ncclUnhandledCudaError;
  }

  return ncclSuccess;
}


static ncclResult_t commClearMaps(ncclComm_t comm) {
  ncclResult_t res, retval = ncclSuccess;
  cudaError_t cures;

  for(int d=0; d<comm->nRanks; ++d) {
    if (comm->ptrs[d].hostCleanup != NULL) {
      cures = cudaHostUnregister(comm->ptrs[d].hostCleanup);
      if (cures != cudaSuccess) {
        WARN("rank %d failed to unregister handle to device %d",
          comm->rank, d);
          retval = (retval == ncclSuccess) ? ncclUnhandledCudaError : retval;
      }
      res = shmUnmap(comm->ptrs[d].hostCleanup, offsetof(ncclMem, buff) + comm->buffSize);
      if (res != ncclSuccess) {
        WARN("rank %d failed to unmap handle to device %d",
          comm->rank, d);
          retval = (retval == ncclSuccess) ? res : retval;
      }
      comm->ptrs[d].hostCleanup = NULL;
    }

    if (comm->ptrs[d].devCleanup != NULL) {
      cures = cudaIpcCloseMemHandle((void*)comm->ptrs[d].devCleanup);
      if (cures != cudaSuccess) {
        WARN("rank %d failed to close IPC handle to device %d: %s",
          comm->rank, d, cudaGetErrorString(cures));
        retval = (retval == ncclSuccess) ? ncclUnhandledCudaError : retval;
      }
    }
  }

  for (int r=0; r<MAXRINGS; ++r) {
    if (comm->userFromRing[r] != NULL)
      memset(comm->userFromRing[r], 0, sizeof(int)*comm->nRanks);
    if (comm->ncclFromRing[r] != NULL)
      memset(comm->ncclFromRing[r], 0, sizeof(int)*comm->nRanks);

    if (comm->devUserFromRing[r] != NULL) {
      cures = cudaMemset(comm->devUserFromRing[r], 0, sizeof(int)*comm->nRanks);
      if (cures != cudaSuccess) {
        WARN("Faild to clear dev map: %s", cudaGetErrorString(cures));
        retval = (retval == ncclSuccess) ? ncclUnhandledCudaError : retval;
      }
    }
  }

  if (comm->devRing != NULL) {
    cures = cudaMemset(comm->devRing, 0, MAXRINGS*sizeof(DevRing<char>));
    if (cures != cudaSuccess) {
      WARN("Failed to clear devRing: %s", cudaGetErrorString(cures));
      retval = (retval == ncclSuccess) ? ncclUnhandledCudaError : retval;
    }
  }
  comm->buffSizePerRing = 0;
  return retval;
}

static ncclResult_t commBuildMaps(ncclComm_t comm, ncclUniqueId* commId, int rank, RankEntry* ranks, int* globalMemSpaceBroke) {
  int ndev = comm->nRanks;
  comm->rank = rank;

  if (ndev > MAXRANKS) {
    WARN("%d ranks exceeds MAXRANKS of %d", ndev, MAXRANKS);
    return ncclUnsupportedDeviceCount;
  }

  // Check for inconsistencies between ranks
  // If two ranks use the same rank, then one slot of
  // ranks[] will be left unset with zero ndev/buffSize.
  for(int i=0; i<ndev; ++i) {
    if (ranks[i].buffSize != comm->buffSize
        || ranks[i].ndev != comm->nRanks) {
      commClearMaps(comm);
      return ncclRankMismatch;
    }
  }

  // Find self among ranks of gather
  int myNcclId = -1;
  for (int i=0; i<ndev; ++i) {
    if(ranks[i].rank == rank) {
      myNcclId = i;
      break;
    }
  }
  if (myNcclId == -1) {
    WARN("rank %d not found in communicator", rank);
    return ncclInvalidRank;
  }

  enum { _PCIE, _NVLINK, _LINK_COUNT } link = _PCIE;
  const char* linkNames[_LINK_COUNT] = { "PCIe", "NVLink" };

  enum { _UNKNOWN, _DGX1, _BB, _PLATFORM_COUNT } platform = _UNKNOWN;
  const char* platformNames[_PLATFORM_COUNT] = { "Unknown", "DGX-1", "BigBasin" };

  enum { _NONE, _CUBEMESH, _HALF_CUBEMESH, _BB_CUBEMESH, _4FC, _4RING, _3FC, _2FC, _TOPO_COUNT } topo = _NONE;
  const char* topoNames[_TOPO_COUNT] = { "none", "cube-mesh", "half cube-mesh", "BigBasin cube-mesh",
    "4 fully-connected", "4 ring", "3 fully-connected", "2 fully-connected" };

  const char* platformName = getenv("NCCL_PLATFORM");
  if(platformName == NULL) {
    // Test NVLink existence
    nvmlDevice_t rank_device;
    ncclResult_t res = wrapNvmlDeviceGetHandleByIndex(ranks[myNcclId].sortId, &rank_device);
    // XXX: 4 is hardcoded here as current limit. Need to adjust potentially in the future
    for(int link_num=0; link_num<4; link_num++){
      nvmlEnableState_t active = NVML_FEATURE_DISABLED;
      res = wrapNvmlDeviceGetNvLinkState(rank_device, link_num, &active);
      if (res == ncclLibWrapperNotSet) {
        // Stop immediately if the symbol is not present
        break;
      }
      if(res == ncclSuccess && active == NVML_FEATURE_ENABLED) {
        int canpeer_0_6 = 0;
        cudaError_t res = cudaDeviceCanAccessPeer(&canpeer_0_6, ranks[0].cudaDev, ranks[6].cudaDev);
        if (res == cudaSuccess && canpeer_0_6) {
          platform = _BB;
        } else {
          platform = _DGX1;
        }
        break;
      }
    }
  }
  else if(strcmp(platformName, "DGX1") == 0) { platform = _DGX1; }
  else if(strcmp(platformName, "BB") == 0) { platform = _BB; }

  if      ((platform == _DGX1) && (ndev == 8)) { link = _NVLINK; topo = _CUBEMESH; }
  else if ((platform == _DGX1) && (ndev == 4)) { link = _NVLINK; topo = _HALF_CUBEMESH; }
  else if ((platform == _DGX1) && (ndev == 3)) { link = _NVLINK; topo = _3FC; }
  else if ((platform == _DGX1) && (ndev == 2)) { link = _NVLINK; topo = _2FC; }
  else if ((platform == _BB)   && (ndev == 8)) { link = _NVLINK; topo = _BB_CUBEMESH; }
  else if ((platform == _BB)   && (ndev == 4)) { link = _NVLINK; topo = _HALF_CUBEMESH; }
  else if ((platform == _BB)   && (ndev == 3)) { link = _NVLINK; topo = _3FC; }
  else if ((platform == _BB)   && (ndev == 2)) { link = _NVLINK; topo = _2FC; }

  const char* topoName = getenv("NCCL_TOPOLOGY");
  if (topoName != NULL) {
    if      ((strcmp(topoName, "CUBEMESH")      == 0) && (ndev == 8)) { link = _NVLINK; topo = _CUBEMESH; }
    else if ((strcmp(topoName, "CUBEMESH")      == 0) && (ndev == 4)) { link = _NVLINK; topo = _HALF_CUBEMESH; }
    else if ((strcmp(topoName, "BB_CUBEMESH")   == 0) && (ndev == 8)) { link = _NVLINK; topo = _BB_CUBEMESH; }
    else if ((strcmp(topoName, "4FC")           == 0) && (ndev == 4)) { link = _NVLINK; topo = _4FC; }
    else if ((strcmp(topoName, "4RING")         == 0) && (ndev == 4)) { link = _NVLINK; topo = _4RING; }
    else if ((strcmp(topoName, "3FC")           == 0) && (ndev == 3)) { link = _NVLINK; topo = _3FC; }
    else if ((strcmp(topoName, "2FC")           == 0) && (ndev == 2)) { link = _NVLINK; topo = _2FC; }
    else {
      INFO("Ignoring NCCL_TOPOLOGY=%s for %d GPUs", topoName, ndev);
    }
  }

  INFO("Topology detection : platform %s, link %s, topo %s", platformNames[platform], linkNames[link], topoNames[topo]);

  if (link == _PCIE) {
    INFO("Using PCIe topology");
    comm->nRings = 1;
    comm->p2ptype = ncclComm::PCIE;
    for(int ringPos=0; ringPos<ndev; ++ringPos) {
      int ncclPos = (ringPos+myNcclId) % ndev; // ring order relative to self
      int userRank = ranks[ncclPos].rank;
      comm->userFromRing[0][ringPos] = userRank;
      comm->ncclFromRing[0][ringPos] = ncclPos;
    }
  } else { // link == _NVLINK
    const int MAXNVLGPUS = 8; // whatever the biggest topology we know about is
    const int MAXNVLRINGS = 6; // usually based on how many NVLinks each GPU has
    int NVLRings[MAXNVLGPUS][MAXNVLRINGS]; // note this is transposed for ease of variable # of GPUs

    comm->p2ptype = ncclComm::NVLINK;

    if (topo == _CUBEMESH) {
      INFO("Using Cube-Mesh topology");
      comm->nRings = 4;
      const int Rings[8][MAXNVLRINGS] = {
          0, 2, 4, 6, -1, -1,
          1, 0, 5, 4, -1, -1,
          2, 3, 6, 7, -1, -1,
          3, 1, 7, 5, -1, -1,
          7, 5, 3, 1, -1, -1,
          6, 7, 2, 3, -1, -1,
          5, 4, 1, 0, -1, -1,
          4, 6, 0, 2, -1, -1};
      memcpy(NVLRings, Rings, sizeof(Rings));
    } else if (topo == _HALF_CUBEMESH) {
      INFO("Using Half Cube-Mesh topology");
      comm->nRings = 6;
      const int HCMRings[4][MAXNVLRINGS] = {
          0, 0, 0, 3, 3, 2,
          1, 2, 1, 2, 1, 3,
          2, 1, 3, 1, 2, 1,
          3, 3, 2, 0, 0, 0};
      memcpy(NVLRings, HCMRings, sizeof(HCMRings));
    } else if (topo == _BB_CUBEMESH) {
      comm->nRings = 4;
      const int Rings[8][MAXNVLRINGS] = {
          0, 0, 0, 0, -1, -1,
          1, 6, 2, 7, -1, -1,
          7, 1, 5, 5, -1, -1,
          6, 3, 3, 4, -1, -1,
          4, 2, 4, 2, -1, -1,
          3, 4, 6, 3, -1, -1,
          5, 5, 7, 1, -1, -1,
          2, 7, 1, 6, -1, -1}; 
      memcpy(NVLRings, Rings, sizeof(Rings));
    } else if (topo == _4FC) {
      INFO("Using 4-FC topology");
      comm->nRings = 4;
      const int Rings[4][MAXNVLRINGS] = {
          0, 0, 3, 2, -1, -1,
          1, 3, 2, 1, -1, -1,
          2, 1, 1, 3, -1, -1,
          3, 2, 0, 0, -1, -1};
      memcpy(NVLRings, Rings, sizeof(Rings));
    } else if (topo == _4RING) {
      INFO("Using 4-Ring topology");
      comm->nRings = 2;
      const int Rings[4][MAXNVLRINGS] = {
          // want to test this and see if it works as
          // well with just two CTAs, else switch back to four rings
          0, 3, -1, -1, -1, -1,
          1, 2, -1, -1, -1, -1,
          2, 1, -1, -1, -1, -1,
          3, 0, -1, -1, -1, -1};
      memcpy(NVLRings, Rings, sizeof(Rings));
    } else if (topo == _3FC) {
      INFO("Using 3-FC topology");
      comm->nRings = 2;
      const int Rings[4][MAXNVLRINGS] = {
          0, 2, -1, -1, -1, -1,
          1, 1, -1, -1, -1, -1,
          2, 0, -1, -1, -1, -1};
      memcpy(NVLRings, Rings, sizeof(Rings));
    } else { // if (topo == _2FC)
      INFO("Using 2-FC topology");
      comm->nRings = 1;
      const int Rings[4][MAXNVLRINGS] = {
          0, -1, -1, -1, -1, -1,
          1, -1, -1, -1, -1, -1};
      memcpy(NVLRings, Rings, sizeof(Rings));
    }

    // Double the number of rings to improve bandwidth
    for(int r=0; r<comm->nRings*2; ++r) {
      int myRingPos=-1;
      for(int p=0; p<ndev; ++p) {
        if (myNcclId == NVLRings[p][r%comm->nRings])
          myRingPos = p;
      }
      if (myRingPos == -1) {
        WARN("rank %d could not find %d in NVLRings[*][%d]",
            rank, myNcclId, r);
        return ncclInternalError;
      }

      for(int ringPos=0; ringPos<ndev; ++ringPos) {
        int absRingPos = (ringPos+myRingPos) % ndev;
        int nccl = NVLRings[absRingPos][r%comm->nRings];
        int userRank = ranks[nccl].rank;
        comm->userFromRing[r][ringPos] = userRank;
        comm->ncclFromRing[r][ringPos] = nccl;
      }
    }
    comm->nRings *= 2;
  }

  int myDev = ranks[myNcclId].cudaDev;
  pid_t myPid = ranks[myNcclId].pid;

  // The order that we link with peers must ensure that
  // P2P slots are used for high-priority links first.
  int* orderedList = (int*)malloc(ndev*sizeof(int));
  int nList = 0;
  for (int r=0; r<comm->nRings; ++r) {
    int nextIdx = (comm->nRanks>0) ? 1 : 0;
    int nextDev = comm->ncclFromRing[r][nextIdx];
    int found = 0;
    for (int p=0; p<nList; ++p) {
      if (orderedList[p] == nextDev)
        found = 1;
    }
    if (!found)
      orderedList[nList++] = nextDev;

    int prevIdx = comm->nRanks - 1;
    int prevDev = comm->ncclFromRing[r][prevIdx];
    found = 0;
    for (int p=0; p<nList; ++p) {
      if (orderedList[p] == prevDev)
        found = 1;
    }
    if (!found)
      orderedList[nList++] = prevDev;
  }
  int loopPeers = nList;
  for (int d=0; d<ndev; ++d) {
    int found = 0;
    for (int p=0; p<nList; ++p) {
      if (orderedList[p] == d)
        found = 1;
    }
    if (!found)
      orderedList[nList++] = d;
  }

  for (int j=0; j<ndev; ++j) {
    int i = orderedList[j];
    int iRank = ranks[i].rank;
    int iDev = ranks[i].cudaDev;
    pid_t iPid = ranks[i].pid;
    int canpeer = 0;

    if (cudaDeviceCanAccessPeer(&canpeer, myDev, iDev) != cudaSuccess) {
      INFO("peer query failed between rank %d (dev %d) and rank %d (dev %d)",
        rank, myDev, iRank, iDev);
      canpeer = 0;
    }

    cudaError_t err;
    ncclMem* remoteHostBuff;

    comm->ptrs[i].type = NodeRef::HOST; // Assume host buffer
    comm->ptrs[i].devCleanup = NULL;
    comm->ptrs[i].hostCleanup = NULL;

    if (iPid == myPid) {
      remoteHostBuff = ranks[i].hostptr;

      if (myDev == iDev) { // shared device
        INFO("rank access %d -> %d via common device", rank, iRank);
        comm->ptrs[i].type = NodeRef::DEVICE;
        comm->ptrs[i].local = ranks[myNcclId].devptr;
        comm->ptrs[i].remote = ranks[i].devptr;
      } else if (canpeer) {
        INFO("rank access %d -> %d via P2P device mem", rank, iRank);
        err = cudaDeviceEnablePeerAccess(iDev, 0);
        if (err == cudaErrorPeerAccessAlreadyEnabled) {
          cudaGetLastError();
        } else if (err != cudaSuccess) {
          WARN("rank %d failed to peer with device %d: %s",
              rank, iDev, cudaGetErrorString(err));
          commClearMaps(comm);
          return ncclUnhandledCudaError;
        }
        comm->ptrs[i].type = NodeRef::DEVICE;
        comm->ptrs[i].local = ranks[myNcclId].devptr;
        comm->ptrs[i].remote = ranks[i].devptr;
      }
    } else { // Separate processes
      *globalMemSpaceBroke = 1;
      char rankname[1024];
      sprintf(rankname, "%s-%d", commId->internal, ranks[i].rank);
      if (openHostMemShm(rankname, &remoteHostBuff, ranks[i].buffSize)
          != ncclSuccess) {
        WARN("rank %d failed to open sysmem buffer of rank %d", rank, iRank);
        commClearMaps(comm);
        return ncclUnhandledCudaError;
      }
      comm->ptrs[i].hostCleanup = remoteHostBuff;

      // TODO: Extend to same device (MPS) case.
      // At present that would go through host mem.
      if (canpeer) {
        INFO("rank access %d -> %d via IPC device mem", rank, iRank);
        comm->ptrs[i].type = NodeRef::DEVICE;
        comm->ptrs[i].local  = ranks[myNcclId].devptr;
        err = cudaIpcOpenMemHandle((void**)(&comm->ptrs[i].remote),
            ranks[i].devipc, cudaIpcMemLazyEnablePeerAccess);
        if (err != cudaSuccess) {
          WARN("rank %d failed to open Ipc handle to rank %d: %s",
              rank, iRank, cudaGetErrorString(err));
          commClearMaps(comm);
          return ncclUnhandledCudaError;
        }
        comm->ptrs[i].devCleanup = comm->ptrs[i].remote;
      }
    }

    err = cudaHostGetDevicePointer(&comm->ptrs[i].opCounter,
          &(remoteHostBuff->opCounter), 0);
    if (err != cudaSuccess) {
      WARN("rank %d failed to obtain %d's zero copy pointer: %s",
          rank, iRank, cudaGetErrorString(err));
      commClearMaps(comm);
      return ncclUnhandledCudaError;
    }

    if (comm->ptrs[i].type == NodeRef::HOST) {
      if (j < loopPeers)
        *globalMemSpaceBroke = 1;
      INFO("rank access %d -> %d via zero-copy host mem", rank, iRank);
      if (cudaHostGetDevicePointer(&comm->ptrs[i].local, ranks[myNcclId].hostptr, 0) != cudaSuccess) {
        WARN("rank %d failed to map zero copy buffer to device", rank);
        commClearMaps(comm);
        return ncclUnhandledCudaError;
      }
      if (cudaHostGetDevicePointer(&comm->ptrs[i].remote, remoteHostBuff, 0) != cudaSuccess) {
        WARN("rank %d failed to map %d's zero copy buffer to device", rank, iRank);
        commClearMaps(comm);
        return ncclUnhandledCudaError;
      }
    }
  }
  free(orderedList);

  // Setup device-side ring view
  int maxBuffPerRing = comm->buffSizePerRing;
  for(int r=0; r<comm->nRings; ++r) {
    if (cudaMemcpy(comm->devUserFromRing[r], comm->userFromRing[r], ndev*sizeof(int),
        cudaMemcpyHostToDevice) != cudaSuccess) {
      WARN("rank %d failed to copy maps to device", rank);
      commClearMaps(comm);
      return ncclUnhandledCudaError;
    }

    DevRing<char> ringTemp;
    memcpy(ringTemp.userRank, comm->userFromRing[r], ndev*sizeof(int));

    int prevIdx = comm->ncclFromRing[r][comm->nRanks-1];
    int nextIdx = comm->ncclFromRing[r][1 % comm->nRanks];
    NodeRef* prevPtrs = comm->ptrs+prevIdx;
    NodeRef* nextPtrs = comm->ptrs+nextIdx;

    ringTemp.prevOpCounter    = prevPtrs->opCounter;
    ringTemp.nextOpCounter    = nextPtrs->opCounter;
    ringTemp.sendFlagToNext   = nextPtrs->remote->flags + 2*r;
    ringTemp.recvFlagFromPrev = prevPtrs->local->flags  + 2*r;
    ringTemp.sendFlagToPrev   = prevPtrs->remote->flags + 2*r+1;
    ringTemp.recvFlagFromNext = nextPtrs->local->flags  + 2*r+1;

    ringTemp.recvPtrFromNext = (char**)nextPtrs->local->recvPtrs + r;
    ringTemp.sendPtrToPrev   = (char**)prevPtrs->remote->recvPtrs + r;

    ringTemp.recvBuffer = prevPtrs->local->buff + r*maxBuffPerRing;
    ringTemp.sendBuffer = nextPtrs->remote->buff + r*maxBuffPerRing;

    if (cudaMemcpy(comm->devRing+r, &ringTemp, sizeof(ringTemp),
        cudaMemcpyHostToDevice) != cudaSuccess) {
      WARN("rank %d failed to copy ring maps to device", rank);
      commClearMaps(comm);
      return ncclUnhandledCudaError;
    }
  }

  return ncclSuccess;
}

static void initDebug() {
  const char* nccl_debug = getenv("NCCL_DEBUG");
  if (nccl_debug == NULL) {
    ncclDebugLevel = NONE;
  } else if (strcmp(nccl_debug, "VERSION") == 0) {
    ncclDebugLevel = VERSION;
  } else if (strcmp(nccl_debug, "WARN") == 0) {
    ncclDebugLevel = WARN;
  } else if (strcmp(nccl_debug, "INFO") == 0) {
    ncclDebugLevel = INFO;
    INFO("NCCL debug level set to INFO");
  } else if (strcmp(nccl_debug, "ABORT") == 0) {
    ncclDebugLevel = ABORT;
    INFO("NCCL debug level set to ABORT");
  }

  const char* nccl_crc = getenv("NCCL_CRC");
  if (nccl_crc != NULL && strcmp(nccl_crc, "PRINT")==0 ) {
    ncclPrintCRCs = 1;
  } else {
    ncclPrintCRCs = 0;
  }
}

static void commFree(ncclComm_t comm) {
  if (comm == NULL)
    return;

  if (comm->doneEvent != NULL)
    if (cudaEventDestroy(comm->doneEvent) != cudaSuccess)
      INFO("ncclComm failed to destroy doneEvent");

  ncclResult_t res = commClearMaps(comm);
  if (res != ncclSuccess)
    INFO("failed to cleanup comm maps");

  if (comm->devRing != NULL)
    if (cudaFree(comm->devRing) != cudaSuccess)
      INFO("commFree failed to free devRing");

  for(int r=0; r<MAXRINGS; ++r) {
    if (comm->userFromRing[r] != NULL)
      free(comm->userFromRing[r]);

    if (comm->devUserFromRing[r] != NULL)
      if (cudaFree(comm->devUserFromRing[r]) != cudaSuccess)
        INFO("commFree failed to free dev maps");

    if (comm->ncclFromRing[r] != NULL)
      free(comm->ncclFromRing[r]);
  }

  if (comm->devMem != NULL && cudaFree(comm->devMem) != cudaSuccess)
    INFO("Failed to free devMap");

  if (comm->hostMem != NULL) {
    if (comm->hostMemState & ShmMapped) {
      if (cudaHostUnregister(comm->hostMem) != cudaSuccess)
        INFO("Failed to unregister hostMem");
      size_t size = offsetof(ncclMem, buff) + comm->buffSize;
      if (shmUnmap(comm->hostMem, size) != ncclSuccess)
        INFO("Failed to unmap hostMem");
      comm->hostMemState ^= ShmMapped;
    } else {
      cudaFreeHost(comm->hostMem);
    }
  }
  free(comm);
}

static ncclResult_t commAlloc(ncclComm_t* comret, int ndev, const ncclUniqueId* commId, int rank) {
  if (ndev < 1) {
    WARN("invalid device count (%d) requested", ndev);
    return ncclUnsupportedDeviceCount;
  }
  if (rank >= ndev || rank < 0) {
    WARN("rank %d exceeds ndev=%d", rank, ndev);
    return ncclInvalidRank;
  }

  size_t commBytes = offsetof(ncclComm, ptrs) + ndev*sizeof(NodeRef);
  struct ncclComm* comm = (struct ncclComm*)malloc(commBytes);
  if (comm == NULL) {
    WARN("comm allocation failed");
    return ncclSystemError;
  }
  memset(comm, 0, commBytes);

  comm->nRanks = ndev;
  cudaGetDevice(&comm->cudaDev);

  const char* str = getenv("NCCL_BUFFSIZE");
  int buffsize;
  if (str != NULL) {
    errno = 0;
    buffsize = strtol(str, NULL, 10);
    if (errno == ERANGE || buffsize == 0) {
      INFO("rank %d invalid NCCL_BUFFSIZE: %s, using default %lu",
          rank, str, DEFAULT_BUFFER_SIZE_BYTES);
      buffsize = DEFAULT_BUFFER_SIZE_BYTES;
    }
  } else {
    buffsize = DEFAULT_BUFFER_SIZE_BYTES;
  }
  comm->buffSizePerRing = buffsize;
  comm->buffSize = comm->buffSizePerRing * MAXRINGS;
  INFO("rank %d using buffSize = %lu, buffSizePerRing = %lu", rank, comm->buffSize, comm->buffSizePerRing);


  ncclResult_t res;
  res = allocDevMem(&comm->devMem, comm->buffSize);
  if (res != ncclSuccess) {
    WARN("rank %d failed to allocate device buffer", rank);
    commFree(comm);
    return res;
  }

  if (cudaMalloc(&comm->devRing, MAXRINGS*sizeof(DevRing<char>)) != cudaSuccess) {
    WARN("rank %d failed to allocate device-side ring views", rank);
    commFree(comm);
    return ncclCudaMallocFailed;
  }

  for(int r=0; r<MAXRINGS; ++r) {
    if (cudaMalloc(&comm->devUserFromRing[r], ndev*sizeof(int)) != cudaSuccess ) {
      WARN("rank %d failed to allocated device maps", rank);
      commFree(comm);
      return ncclCudaMallocFailed;
    }

    comm->userFromRing[r] = (int*)malloc(ndev*sizeof(int));
    if (comm->userFromRing[r] == NULL) {
      WARN("rank %d failed to allocate host maps", rank);
      commFree(comm);
      return ncclSystemError;
    }

    comm->ncclFromRing[r] = (int*)malloc(ndev*sizeof(int));
    if (comm->ncclFromRing[r] == NULL) {
      WARN("rank %d failed to allocate host maps", rank);
      commFree(comm);
      return ncclSystemError;
    }
  }

  if (cudaEventCreateWithFlags(&comm->doneEvent, cudaEventDisableTiming) != cudaSuccess) {
    WARN("ncclComm on rank %d failed to create doneEvent", rank);
    commFree(comm);
    return ncclUnhandledCudaError;
  }

  if(commId == NULL) {
    comm->hostMemState = 0;
    res = allocHostMem(&comm->hostMem, comm->buffSize);
  } else {
    char rankname[1024];
    sprintf(rankname, "%s-%d", commId->internal, rank);
    res = openHostMemShm(rankname, &comm->hostMem, comm->buffSize);
    if (res != ncclSuccess) {
      WARN("rank %d failed to allocate host buffer", rank);
      commFree(comm);
      return res;
    }
    comm->hostMemState = ShmMapped | ShmLinked;
  }

  if (cudaHostGetDevicePointer(&comm->opCounter, &comm->hostMem->opCounter, 0) != cudaSuccess) {
    WARN("ncclComm on rank %d failed to map opCounter to device", rank);
    commFree(comm);
    return ncclUnhandledCudaError;
  }

  *comret = comm;
  return ncclSuccess;
}

static ncclResult_t devCommUpdate(ncclComm_t comm) {
  // Copy the comm on the device
  size_t commBytes = offsetof(ncclComm, ptrs) + comm->nRanks*sizeof(NodeRef);
  if (cudaMemcpy(comm->devComm, comm, commBytes, cudaMemcpyHostToDevice) != cudaSuccess) {
    WARN("failed to copy device comm");
    return ncclUnhandledCudaError;
  }
  // Fix the host pointer to be accessible from the device
  void* dptr;
  if (cudaHostGetDevicePointer(&dptr, comm->hostMem, 0) != cudaSuccess) {
    WARN("failed to get device pointer for host mem");
    return ncclUnhandledCudaError;
  }
  if (cudaMemcpy(&comm->devComm->hostMem, &dptr, sizeof(dptr), cudaMemcpyHostToDevice) != cudaSuccess) {
    WARN("failed to update host pointer");
    return ncclUnhandledCudaError;
  }
  return ncclSuccess;
}

static ncclResult_t devCommSetup(ncclComm_t comm) {
  // Fully duplicate the comm on the device
  size_t commBytes = offsetof(ncclComm, ptrs) + comm->nRanks*sizeof(NodeRef);
  if (cudaMalloc(&comm->devComm, commBytes) != cudaSuccess) {
    WARN("failed to allocated device comm");
    return ncclCudaMallocFailed;
  }
  return devCommUpdate(comm);
}

static ncclResult_t commUnlinkHostMem(ncclComm_t comm, ncclUniqueId commId, int rank) {
  char rankname[1024];
  sprintf(rankname, "%s-%d", commId.internal, rank);
  if (comm->hostMemState & ShmLinked)
    comm->hostMemState ^= ShmLinked;
  return shmUnlink(rankname);
}

static void showVersion() {
  static int shown = 0;
  if (shown == 0 && ncclDebugLevel >= VERSION) {
    printf("NCCL version %d.%d.%d compiled with CUDA %d.%d\n", NCCL_MAJOR, NCCL_MINOR, NCCL_PATCH, CUDA_MAJOR, CUDA_MINOR);
    fflush(stdout);
    shown = 1;
  }
}

NCCL_API(ncclResult_t, ncclCommInitRank, ncclComm_t* newcomm, int ndev, ncclUniqueId commId, int myrank);
ncclResult_t ncclCommInitRank(ncclComm_t* newcomm, int ndev, ncclUniqueId commId, int myrank) {
  if (myrank == 0) showVersion();

  if (strlen(commId.internal) < 1 ||
      strlen(commId.internal) >= NCCL_UNIQUE_ID_BYTES) {
    WARN("rank %d invalid commId", myrank);
    return ncclInvalidArgument;
  }

  initDebug();
  ncclResult_t res;
  RankEntry myStuff;
  RankGather* gath = NULL;

  res = wrapSymbols();
  if (res != ncclSuccess) {
    WARN("NCCL failed to initialize client libs");
    return res;
  }

  res = wrapNvmlInit();
  if (res != ncclSuccess) {
    WARN("rank %d failed to initialize nvml", myrank);
    return res;
  }

  res = commAlloc(newcomm, ndev, &commId, myrank);
  if (res != ncclSuccess) {
    WARN("rank %d failed to allocate communicator", myrank);
    return res;
  }

  res = populateRankInfo(&myStuff, myrank, *newcomm);
  if (res != ncclSuccess) {
    WARN("rank %d failed to obtain rank info", myrank);
    goto cleanup;
  }

  res = initGather(&gath, commId, ndev, myrank, myStuff);
  if (res != ncclSuccess) {
    WARN("rank %d failed to gather rank info", myrank);
    goto cleanup;
  }

  res = commBuildMaps(*newcomm, &commId, myrank, gath->ranks, &gath->globalMemSpaceBroke);
  if (res != ncclSuccess) {
    WARN("rank %d failed to build comm maps", myrank);
    goto cleanup;
  }

  syncRingDirect(gath, &((*newcomm)->globalMemSpace));
  INFO("Global device memory space is %s", (*newcomm)->globalMemSpace ? "enabled" : "disabled");

  res = closeGather(gath, ndev); // includes a barrier
  gath = NULL;
  if (res != ncclSuccess) {
    WARN("rank %d failed to close gather", myrank);
    goto cleanup;
  }

  res = devCommSetup(*newcomm);
  if (res != ncclSuccess) {
    WARN("rank %d failed to copy dcomm", myrank);
    goto cleanup;
  }

  res = ncclSuccess;
  goto final;

  cleanup:
  if (gath != NULL)
    closeGather(gath, ndev);
  commFree(*newcomm);

  final:
  if ((*newcomm)->hostMemState & ShmLinked) {
    if (commUnlinkHostMem(*newcomm, commId, myrank) != ncclSuccess)
      INFO("rank %d failed to unlink host mem shm segment", myrank);
  }

  if (wrapNvmlShutdown() != ncclSuccess)
    INFO("rank %d did not shutdown nvml properly", myrank);
  return res;
}

NCCL_API(ncclResult_t, ncclCommInitAll, ncclComm_t* comms, int ndev, int* devlist);
ncclResult_t ncclCommInitAll(ncclComm_t* comms, int ndev, int* devlist) {
  initDebug();

  showVersion();

  ncclResult_t res;
  int savedDevice;
  RankEntry* ranks = NULL;
  int rank, cudaDev;
  ncclComm_t comm = NULL;
  char busId[13];
  nvmlDevice_t nvmlHandle;
  int affinity_set = 0;
  int globalMemSpaceBroke = 0; // Assume direct access to recv ptr OK

  res = wrapSymbols();
  if (res != ncclSuccess) {
    WARN("NCCL failed to initialize client libs");
    return res;
  }

  cudaGetDevice(&savedDevice);
  ranks = (RankEntry*)malloc(ndev*sizeof(RankEntry));
  if (ranks == NULL) {
    WARN("NCCL allocation failed");
    return ncclSystemError;
  }
  memset(ranks, 0, ndev*sizeof(RankEntry));

  res = wrapNvmlInit();
  if (res != ncclSuccess) {
    WARN("nccl failed to initialize nvml");
    return res;
  }

  for(rank=0; rank<ndev; ++rank)
    comms[rank] = NULL;

  for (rank=0; rank<ndev; ++rank) {
    cudaDev = (devlist == NULL) ? rank : devlist[rank];
    if (cudaSetDevice(cudaDev) != cudaSuccess) {
      WARN("rank %d failed to set cuda device %d", rank, cudaDev);
      res = ncclInvalidDeviceIndex;
      goto cleanup;
    }

    // Set CPU affinity
    affinity_set = 0;
    if (cudaDeviceGetPCIBusId(busId, 13, cudaDev) != cudaSuccess) {
      INFO("rank %d failed to get PCI Bus Id for device %d", rank, cudaDev);
      goto skipaffinity;
    }
    if (wrapNvmlDeviceGetHandleByPciBusId(busId, &nvmlHandle) != ncclSuccess) {
      INFO("rank %d failed to get nvml handle for device %s", rank, busId);
      goto skipaffinity;
    }
    if (wrapNvmlDeviceSetCpuAffinity(nvmlHandle) != ncclSuccess) {
      INFO("rank %d failed to set affinity", rank);
      goto skipaffinity;
    }
    affinity_set = 1;
    skipaffinity:

    res = commAlloc(&comm, ndev, NULL, rank);
    if (res != ncclSuccess) {
      WARN("rank %d failed to allocate communicator", rank);
      goto cleanup;
    }
    comms[rank] = comm;

    if (affinity_set && wrapNvmlDeviceClearCpuAffinity(nvmlHandle) != ncclSuccess) {
      INFO("rank %d set but failed to clear cpu affinity", rank);
    }
    res = populateRankInfo(ranks+rank, rank, comm);
    if (res != ncclSuccess) {
      WARN("rank %d failed to obtain rank info", rank);
      goto cleanup;
    }
  }

  orderRanks(ranks, ndev);
  for(rank=0; rank<ndev; ++rank) {
    comm = comms[rank];
    cudaSetDevice(comm->cudaDev);
    res = commBuildMaps(comm, NULL, rank, ranks, &globalMemSpaceBroke);
    if (res != ncclSuccess) {
      WARN("rank %d failed to build comm maps", rank);
      goto cleanup;
    }
  }

  INFO("Global device memory space is %s", (globalMemSpaceBroke) ? "disabled" : "enabled");
  for(rank=0; rank<ndev; ++rank) {
    comms[rank]->globalMemSpace = globalMemSpaceBroke ? 0 : 1;
  }
 
  for(rank=0; rank<ndev; ++rank) {
    res = devCommSetup(comms[rank]);
    if (res != ncclSuccess) {
      WARN("rank %d failed to copy dcomm", rank);
      goto cleanup;
    }
  }

  free(ranks);
  ranks = NULL;
  res = ncclSuccess;
  goto final;

  cleanup:
  if (ranks != NULL)
    free(ranks);
  for(rank=0; rank<ndev; ++rank) {
    if(comms[rank] != NULL) {
      commFree(comms[rank]);
    }
  }

  final:
  if(wrapNvmlShutdown() != ncclSuccess)
    INFO("NCCL did not shutdown nvml properly");
  cudaSetDevice(savedDevice);
  return res;
}

NCCL_API(void, ncclCommDestroy, ncclComm_t comm);
void ncclCommDestroy(ncclComm_t comm) {
  if (comm == NULL)
    return;

  int savedDevice;
  cudaGetDevice(&savedDevice);
  int commDevice = comm->cudaDev;

  if (savedDevice != commDevice) {
    CUDACHECK(cudaSetDevice(commDevice));
  }

  commFree(comm);

  if (savedDevice != commDevice)
    cudaSetDevice(savedDevice);
}

NCCL_API(const char*, ncclGetErrorString, ncclResult_t code);
const char* ncclGetErrorString(ncclResult_t code) {
  switch (code) {
  case ncclSuccess                : return "no error";
  case ncclUnhandledCudaError     : return "unhandled cuda error";
  case ncclSystemError            : return "system error";
  case ncclInternalError          : return "internal error";
  case ncclInvalidDevicePointer   : return "invalid device pointer";
  case ncclInvalidRank            : return "invalid rank";
  case ncclUnsupportedDeviceCount : return "unsupported device count";
  case ncclDeviceNotFound         : return "device not found";
  case ncclInvalidDeviceIndex     : return "invalid device index";
  case ncclLibWrapperNotSet       : return "lib wrapper not initialized";
  case ncclCudaMallocFailed       : return "cuda malloc failed";
  case ncclRankMismatch           : return "parameter mismatch between ranks";
  case ncclInvalidArgument        : return "invalid argument";
  case ncclInvalidType            : return "invalid data type";
  case ncclInvalidOperation       : return "invalid reduction operations";
  }
  return "unknown result code";
}

NCCL_API(ncclResult_t, ncclCommCount, const ncclComm_t comm, int* count);
ncclResult_t ncclCommCount(const ncclComm_t comm, int* count) {
  *count = comm->nRanks;
  return ncclSuccess;
}

NCCL_API(ncclResult_t, ncclCommCuDevice, const ncclComm_t comm, int* devid);
ncclResult_t ncclCommCuDevice(const ncclComm_t comm, int* devid) {
  *devid = comm->cudaDev;
  return ncclSuccess;
}

NCCL_API(ncclResult_t, ncclCommUserRank, const ncclComm_t comm, int* rank);
ncclResult_t ncclCommUserRank(const ncclComm_t comm, int* rank) {
  *rank = comm->rank;
  return ncclSuccess;
}

