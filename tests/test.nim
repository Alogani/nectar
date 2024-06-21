import std/deques, std/posix
import aloganimisc/fasttest


type Test {.package.} = object

type Test = object
  a: int

proc eventfd(count: cuint, flags: cint): cint
     {.cdecl, importc: "eventfd", header: "<sys/eventfd.h>".}

var chan: Channel[int]
chan.open()
runBench():
  chan.send(1)
  discard chan.recv()


var deq: Deque[int]
runBench():
  deq.addLast(1)
  discard deq.popFirst()

var evfd = eventfd(0, 0)
runBench():
  var data = 1'u64
  discard write(evfd, addr data, 1)