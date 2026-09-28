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
	rm -rf $(OBJS) $(PROG) axdec libaceapex_decode.so

# aceapex_api.cpp #includes aceapex_main.cpp; make must see that edge.
src/aceapex_api.o: src/aceapex_main.cpp src/aceapex.h src/ax_align.h

# Standalone C99 decoder (no C++, no threads): CLI and a shared library for bindings.
axdec: c/axdec.c c/aceapex_decode.c c/aceapex_decode.h
	$(CC) -std=c99 -O2 -Wall -Ic $(ZSTD_CFLAGS) -o $@ c/axdec.c c/aceapex_decode.c $(ZSTD_LIBS)

libaceapex_decode.so: c/aceapex_decode.c c/aceapex_decode.h
	$(CC) -std=c99 -O2 -Wall -fPIC -shared -Ic $(ZSTD_CFLAGS) -o $@ c/aceapex_decode.c $(ZSTD_LIBS)

test:
	./verify.sh HEAD
