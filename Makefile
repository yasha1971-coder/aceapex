CC ?= gcc
CXX ?= g++
CXXFLAGS = -std=c++17 -O3 -march=native -funroll-loops -DACEAPEX_CLI
LD = $(CXX)
PKG_CONFIG ?= pkg-config
ZSTD_CFLAGS := $(shell $(PKG_CONFIG) --cflags libzstd 2>/dev/null)
ZSTD_LIBS := $(shell $(PKG_CONFIG) --libs libzstd 2>/dev/null)

ifeq ($(strip $(ZSTD_LIBS)),)
ZSTD_LIBS := -lzstd
endif

PROG = aceapex
# The CLI is the library plus main(): one translation unit, one copy of the codec.
SRCS = src/aceapex_api.cpp
OBJS := $(SRCS:.cpp=.o)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) $(ZSTD_CFLAGS) -Isrc -c -o $@ $<

all: $(PROG)

$(PROG): $(OBJS)
	$(LD) -o $@ $^ -lpthread $(ZSTD_LIBS)

clean:
	rm -rf $(OBJS) $(PROG) axdec libaceapex_decode.so libaceapex_gpu.so.1 libaceapex_gpu.so

# aceapex_api.cpp #includes aceapex_main.cpp; make must see that edge.
src/aceapex_api.o: src/aceapex_main.cpp src/aceapex.h src/ax_align.h

# Standalone C99 decoder (no C++, no threads): CLI and a shared library for bindings.
axdec: c/axdec.c c/aceapex_decode.c c/aceapex_decode.h
	$(CC) -std=c99 -O2 -Wall -Ic $(ZSTD_CFLAGS) -o $@ c/axdec.c c/aceapex_decode.c $(ZSTD_LIBS)

libaceapex_decode.so: c/aceapex_decode.c c/aceapex_decode.h
	$(CC) -std=c99 -O2 -Wall -fPIC -shared -Ic $(ZSTD_CFLAGS) -o $@ c/aceapex_decode.c $(ZSTD_LIBS)

# GPU library (C ABI src/aceapex_gpu.h), shared: libaceapex_gpu.so.1 (SONAME) + libaceapex_gpu.so -> .so.1.
# NVCOMP=<nvCOMP dir> (include/, lib64/) adds zstd frames (nvCOMP 5 + libzstd for ACEAPEX_GPU_VALIDATE_ZSTD);
# without it the library decodes the open profile only. GPU_ARCH: nvcc arch flags (default sm_75 code + PTX).
NVCC ?= nvcc
GPU_ARCH ?= -gencode arch=compute_75,code=sm_75 -gencode arch=compute_75,code=compute_75
GPU_NV := $(if $(NVCOMP),-DACEAPEX_GPU_NVCOMP -I$(NVCOMP)/include -L$(NVCOMP)/lib64 -l:libnvcomp.so.5 -lzstd,)
gpu-lib: libaceapex_gpu.so.1

libaceapex_gpu.so.1: src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp src/aceapex_gpu.h src/aceapex_gpu_plan.h src/aceapex_gpu_kernels.cuh src/ax_vec.h src/ax_xxh3.h
	$(NVCC) -std=c++17 -O3 $(GPU_ARCH) -Isrc -shared -Xcompiler -fPIC -Xlinker -soname=libaceapex_gpu.so.1 \
		-o $@ src/aceapex_gpu_lib.cu src/aceapex_gpu_abi.cpp $(GPU_NV)
	ln -sf libaceapex_gpu.so.1 libaceapex_gpu.so

test:
	./verify.sh HEAD
