when not declared(includeUnixCommons):
  {.push used.}
  {.warning[UnusedImport]: false.}

import std/[posix, oserrors]
import std/[sets, tables, heapqueue, monotimes, times]
import std/[atomics, locks]
import std/cpuinfo

const IoPoolSize* {.intdefine.} = 0


proc eventfd(count: cuint, flags: cint): cint
     {.cdecl, importc: "eventfd", header: "<sys/eventfd.h>".}


type
  AsyncFd = distinct FileHandle

  Event {.pure.} = enum
    Read, Write

  UserEvent = object
    # Event in unix can be read/write and act as a semaphore
    # We simplify that usage to save a syscall by using indefferently one or the other
    fd: cint
    current: Event

  IoOperation* = object
    kind: Event
    userData: pointer
    buffer: pointer
    bytesRequested: int
    bytesTransfered: int


proc getMaxThreads(): int =
  if IoPoolSize > 0:
    return IoPoolSize
  else:
    return countProcessors()


proc newAsyncFd(fd: FileHandle): AsyncFd =
  ## AsyncFd will become non blocking
  if fcntl(fd, F_SETFD, O_NONBLOCK) == -1:
    raiseOsError(osLastError())
  return AsyncFd(fd)

proc closeAsyncFd(fd: AsyncFd) =
  if close(fd.cint) == -1:
    raiseOsError(osLastError())


proc `=copy`*(dest: var UserEvent, src: UserEvent) {.error.}

proc newUserEvent*(): UserEvent =
  let fd = eventfd(0, O_CLOEXEC or O_NONBLOCK)
  if fd == -1:
    raiseOsError(osLastError())
  UserEvent(fd: fd, current: Event.Write)

proc trigger*(userEvent: var UserEvent) =
  ## It is a one shot, so can be triggered multiple times (small risk of data race)
  var data = 1'u64
  if userEvent.current == Event.Read:
    if read(userEvent.fd, addr data, sizeof(uint64)) == -1:
      raiseOsError(osLastError())
  else:
    if write(userEvent.fd, addr data, sizeof(uint64)) == -1:
      raiseOsError(osLastError())
