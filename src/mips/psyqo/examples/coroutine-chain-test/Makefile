TARGET = coroutine-chain-test
TYPE = ps-exe

SRCS = \
coroutine-chain-test.cpp \

ifeq ($(TEST),true)
CPPFLAGS = -Werror
endif
CXXFLAGS = -std=c++20 -fcoroutines

include ../../../psyqo-paths/psyqo-paths.mk
