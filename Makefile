CC ?= gcc
CXX ?= g++
CXXFLAGS = -std=c++17 -O3 -march=native -funroll-loops
LD = $(CXX)

PROG = aceapex
SRCS = src/aceapex_main.cpp
OBJS := $(SRCS:.cpp=.o)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

all: $(PROG)

$(PROG): $(OBJS)
	$(LD) -o $@ $^ -lpthread -lzstd

clean:
	rm -rf $(OBJS) $(PROG)
