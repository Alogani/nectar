# Nectar

It stands for Nim Event Completion Toolkit for Asynchronous Routines.

Nectar implements a high level cross platform API above IOCP, EPOLL, POLL, KQUEUE and SELECT. It is a high-performance, cross-platform I/O completion-based event handling library for the Nim programming language.

It provides a unified API that wraps the underlying primitives of epoll, poll, select, kqueue, and IOCP, allowing developers to write efficient, asynchronous network applications with a powerful and efficient API based on the completion model.

Nectar is designed to be fast, lightweight, and easy to use, making it an ideal choice for building scalable, concurrent systems.

## Features

- Cross platform
- Leverage a dynamically sized IO thread pool
- Simple API
- Doesn't restrict to sockets, but also works on files and pipes
