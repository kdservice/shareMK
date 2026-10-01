import Foundation

typealias libusb_context = OpaquePointer
typealias libusb_device_handle = OpaquePointer

@_silgen_name("libusb_init")
func libusb_init(_ context: UnsafeMutablePointer<libusb_context?>?) -> Int32

@_silgen_name("libusb_exit")
func libusb_exit(_ context: libusb_context?)

@_silgen_name("libusb_open_device_with_vid_pid")
func libusb_open_device_with_vid_pid(_ context: libusb_context?, _ vendorID: UInt16, _ productID: UInt16) -> libusb_device_handle?

@_silgen_name("libusb_close")
func libusb_close(_ handle: libusb_device_handle?)

@_silgen_name("libusb_reset_device")
func libusb_reset_device(_ handle: libusb_device_handle?) -> Int32

@_silgen_name("libusb_claim_interface")
func libusb_claim_interface(_ handle: libusb_device_handle?, _ interfaceNumber: Int32) -> Int32

@_silgen_name("libusb_set_auto_detach_kernel_driver")
func libusb_set_auto_detach_kernel_driver(_ handle: libusb_device_handle?, _ enable: Int32) -> Int32

@_silgen_name("libusb_get_configuration")
func libusb_get_configuration(_ handle: libusb_device_handle?, _ configuration: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("libusb_set_configuration")
func libusb_set_configuration(_ handle: libusb_device_handle?, _ configuration: Int32) -> Int32

@_silgen_name("libusb_release_interface")
func libusb_release_interface(_ handle: libusb_device_handle?, _ interfaceNumber: Int32) -> Int32

@_silgen_name("libusb_kernel_driver_active")
func libusb_kernel_driver_active(_ handle: libusb_device_handle?, _ interfaceNumber: Int32) -> Int32

@_silgen_name("libusb_detach_kernel_driver")
func libusb_detach_kernel_driver(_ handle: libusb_device_handle?, _ interfaceNumber: Int32) -> Int32

@_silgen_name("libusb_control_transfer")
func libusb_control_transfer(_ handle: libusb_device_handle?,
                             _ requestType: UInt8,
                             _ request: UInt8,
                             _ value: UInt16,
                             _ index: UInt16,
                             _ data: UnsafeMutablePointer<UInt8>?,
                             _ length: UInt16,
                             _ timeout: UInt32) -> Int32

@_silgen_name("libusb_interrupt_transfer")
func libusb_interrupt_transfer(_ handle: libusb_device_handle?,
                               _ endpoint: UInt8,
                               _ data: UnsafeMutablePointer<UInt8>?,
                               _ length: Int32,
                               _ actualLength: UnsafeMutablePointer<Int32>?,
                               _ timeout: UInt32) -> Int32

@_silgen_name("libusb_bulk_transfer")
func libusb_bulk_transfer(_ handle: libusb_device_handle?,
                          _ endpoint: UInt8,
                          _ data: UnsafeMutablePointer<UInt8>?,
                          _ length: Int32,
                          _ actualLength: UnsafeMutablePointer<Int32>?,
                          _ timeout: UInt32) -> Int32

@_silgen_name("libusb_strerror")
func libusb_strerror(_ errorCode: Int32) -> UnsafePointer<CChar>?

func libusbError(_ code: Int32) -> String {
    guard let cString = libusb_strerror(code) else { return "libusb error \(code)" }
    return String(cString: cString)
}
