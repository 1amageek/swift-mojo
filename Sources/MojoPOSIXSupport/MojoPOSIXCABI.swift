let SWIFT_MOJO_POSIX_SPAWN_SUCCEEDED: Int32 = 0
let SWIFT_MOJO_POSIX_SPAWN_LAUNCH_FAILED: Int32 = -2

let SWIFT_MOJO_POSIX_WORKER_SPAWN_SUCCEEDED: Int32 = 0
let SWIFT_MOJO_POSIX_WORKER_SPAWN_LAUNCH_FAILED: Int32 = -2

let SWIFT_MOJO_POSIX_WORKER_INTEREST_READ: Int32 = 1
let SWIFT_MOJO_POSIX_WORKER_INTEREST_WRITE: Int32 = 2

let SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_READABLE: Int32 = 1
let SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_WRITABLE: Int32 = 2
let SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_READABLE: Int32 = 4
let SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_READABLE: Int32 = 8
let SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_HANGUP: Int32 = 16
let SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_HANGUP: Int32 = 32
let SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_HANGUP: Int32 = 64
let SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_ERROR: Int32 = 128
let SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_ERROR: Int32 = 256
let SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_ERROR: Int32 = 512

@_extern(c, "swift_mojo_posix_platform_supported")
func swift_mojo_posix_platform_supported() -> Int32

@_extern(c, "swift_mojo_posix_open_file")
func swift_mojo_posix_open_file(
  _ path: UnsafePointer<CChar>?,
  _ truncate: Int32,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_close_file")
func swift_mojo_posix_close_file(
  _ descriptor: Int32,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_lock_exclusive")
func swift_mojo_posix_lock_exclusive(
  _ descriptor: Int32,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_try_lock_exclusive")
func swift_mojo_posix_try_lock_exclusive(
  _ descriptor: Int32,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_unlock")
func swift_mojo_posix_unlock(
  _ descriptor: Int32,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_spawn")
func swift_mojo_posix_spawn(
  _ executable: UnsafePointer<CChar>?,
  _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
  _ environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
  _ outputDescriptor: Int32,
  _ processID: UnsafeMutablePointer<Int32>?,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_worker_platform_supported")
func swift_mojo_posix_worker_platform_supported() -> Int32

@_extern(c, "swift_mojo_posix_worker_spawn")
func swift_mojo_posix_worker_spawn(
  _ executable: UnsafePointer<CChar>?,
  _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
  _ environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
  _ protocolDescriptor: UnsafeMutablePointer<Int32>?,
  _ diagnosticDescriptor: UnsafeMutablePointer<Int32>?,
  _ processID: UnsafeMutablePointer<Int32>?,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_worker_create_wakeup")
func swift_mojo_posix_worker_create_wakeup(
  _ readDescriptor: UnsafeMutablePointer<Int32>?,
  _ writeDescriptor: UnsafeMutablePointer<Int32>?,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_worker_signal_wakeup")
func swift_mojo_posix_worker_signal_wakeup(
  _ writeDescriptor: Int32,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_worker_poll")
func swift_mojo_posix_worker_poll(
  _ protocolDescriptor: Int32,
  _ diagnosticDescriptor: Int32,
  _ wakeupDescriptor: Int32,
  _ interests: Int32,
  _ timeoutMilliseconds: Int32,
  _ eventMask: UnsafeMutablePointer<Int32>?,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_worker_read")
func swift_mojo_posix_worker_read(
  _ descriptor: Int32,
  _ buffer: UnsafeMutableRawPointer?,
  _ count: Int64,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int64

@_extern(c, "swift_mojo_posix_worker_write")
func swift_mojo_posix_worker_write(
  _ descriptor: Int32,
  _ buffer: UnsafeRawPointer?,
  _ count: Int64,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int64

@_extern(c, "swift_mojo_posix_wait_nohang")
func swift_mojo_posix_wait_nohang(
  _ processID: Int32,
  _ waitStatus: UnsafeMutablePointer<Int32>?,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_observe_child_nohang")
func swift_mojo_posix_observe_child_nohang(
  _ processID: Int32,
  _ exitStatus: UnsafeMutablePointer<Int32>?,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_signal_group")
func swift_mojo_posix_signal_group(
  _ processID: Int32,
  _ signalNumber: Int32,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int32

@_extern(c, "swift_mojo_posix_process_group_state")
func swift_mojo_posix_process_group_state(
  _ processID: Int32,
  _ maximumEntries: Int32
) -> Int32

@_extern(c, "swift_mojo_posix_process_alive")
func swift_mojo_posix_process_alive(_ processID: Int32) -> Int32

@_extern(c, "swift_mojo_posix_seek_start")
func swift_mojo_posix_seek_start(
  _ descriptor: Int32,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int64

@_extern(c, "swift_mojo_posix_read")
func swift_mojo_posix_read(
  _ descriptor: Int32,
  _ buffer: UnsafeMutableRawPointer?,
  _ count: Int64,
  _ errorCode: UnsafeMutablePointer<Int32>?
) -> Int64

@_extern(c, "swift_mojo_posix_error_is_no_child")
func swift_mojo_posix_error_is_no_child(_ errorCode: Int32) -> Int32

@_extern(c, "swift_mojo_posix_error_is_interrupted")
func swift_mojo_posix_error_is_interrupted(_ errorCode: Int32) -> Int32

@_extern(c, "swift_mojo_posix_error_is_would_block")
func swift_mojo_posix_error_is_would_block(_ errorCode: Int32) -> Int32

@_extern(c, "swift_mojo_posix_termination_signal")
func swift_mojo_posix_termination_signal() -> Int32

@_extern(c, "swift_mojo_posix_kill_signal")
func swift_mojo_posix_kill_signal() -> Int32

@_extern(c, "swift_mojo_posix_error_description")
func swift_mojo_posix_error_description(
  _ errorCode: Int32
) -> UnsafePointer<CChar>

@_extern(c, "swift_mojo_posix_exit")
func swift_mojo_posix_exit(_ status: Int32)
