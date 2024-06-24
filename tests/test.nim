import nectar/nectar_epoll {.all.}

var fd = newAsyncFd(0)
registerHandle(fd, {Event.Read})
var loopThread: Thread[void]
createThread(loopThread, masterLoop)


var buffer = newString(1024)
var ioOperation = initIoOperation(nil)
readFileAsync(fd, addr(buffer[0]), 10, addr ioOperation)
var ioOpPtr = getNextCompletedIoOperation()
echo "same ? ", addr(ioOperation) == ioOpPtr
echo "buffer= ", buffer