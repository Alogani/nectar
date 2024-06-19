import std/[posix, epoll, oserrors, sets]


const IoPoolSize* {.intdefine.} = 0


type
  AsyncFd = distinct FileHandle

  Event {.pure.} = enum
    Read, Write

  Selector = object
    epollFd: FileHandle
    readReadyList: HashSet[FileHandle]
    writeReadyList: HashSet[FileHandle]

  IoCompletionPoolObj = object
    selfThread: Thread[void]
    selector: Selector
    stopFlag: bool
  IoCompletionPool* = ptr IoCompletionPoolObj

const MaxEpollEvents = 64

proc toEpollEvent(events: set[Event]): uint32 =
  result = EPOLLET or EPOLLRDHUP
  if Event.Read in events:
    result = result or EPOLLIN
  if Event.Write in events:
    result = result or EPOLLOUT


proc newAsyncFd(fd: FileHandle): AsyncFd =
  ## AsyncFd will become non blocking
  if fcntl(fd, F_SETFD, O_NONBLOCK) == -1:
    raiseOsError(osLastError())
  return AsyncFd(fd)

proc closeAsyncFd(fd: AsyncFd) =
  if close(fd.cint) == -1:
    raiseOsError(osLastError())


proc newSelector(): Selector =
  Selector(epollFd: epoll_create1(0))

proc registerHandle(selector: var Selector, fd: AsyncFd, events: set[Event]) =
  var epv = EpollEvent(events: toEpollEvent(events))
  if epoll_ctl(selector.epollFd, EPOLL_CTL_ADD, fd.cint, addr epv) != 0:
    raiseOsError(osLastError())

proc select(selector: var Selector, timeoutMs: int): int =
  var epvTable: array[MaxEpollEvents, EpollEvent]
  let count = epoll_wait(selector.epollFd, addr epvTable[0], MaxEpollEvents, timeoutMs.cint)
  if count == -1:
    raiseOsError(osLastError())
  for epv in epvTable:
    let epvEvents = epv.events.int
    if (epvEvents and EPOLLERR) != 0:
      raiseOsError(osLastError()) # TODO: https://github.com/nim-lang/Nim/blob/646bd99d461469f08e656f92ae278d6695b35778/lib/pure/ioselects/ioselectors_epoll.nim#L400
    if (epvEvents and EPOLLIN) != 0:
      selector.readReadyList.incl(epv.data.fd)
    if (epvEvents and EPOLLOUT) != 0:
      selector.writeReadyList.incl(epv.data.fd)
  return count




