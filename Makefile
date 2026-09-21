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
	rm -rf $(OBJS) $(PROG)
