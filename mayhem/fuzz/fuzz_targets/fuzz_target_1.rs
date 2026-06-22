#![no_main]
use libfuzzer_sys::fuzz_target;

use std::ptr::NonNull;
use acpi::{Handle, Handler, PhysicalMapping};
use acpi::aml::AmlError;
use pci_types::PciAddress;

// Fuzz the ACPI AML bytecode interpreter: aml_test_tools::new_interpreter(..).load_table(data).
// `load_table` is the same job the old fork's `acpi` target drove (parse/execute an attacker AML
// stream); upstream renamed `aml::AmlContext::parse_table` -> `acpi::aml::Interpreter::load_table`
// during a workspace refactor. We build the interpreter via upstream's own test-constructor (which
// supplies the fake FixedRegisters + FACS the VM requires) and feed it the raw fuzz bytes.
fuzz_target!(|data: &[u8]| {
    let interp = aml_test_tools::new_interpreter(FuzzHandler);
    let _ = interp.load_table(data);
});

// ASan: the AML VM maps OperationRegions through Handler::map_physical_region; we hand it real
// (zeroed, leaked) memory so reads/writes stay in-bounds, and make unmap a no-op (the interpreter's
// fake FACS mapping points at a `static`, so freeing in unmap would corrupt it). Disable ASan leak
// detection so those bounded per-input region maps aren't reported as leaks.
#[no_mangle]
pub extern "C" fn __asan_default_options() -> *const u8 {
    b"detect_leaks=0\0".as_ptr()
}

// A permissive, non-panicking Handler (unlike upstream's NullHandler, whose map_physical_region is
// `todo!()` and would crash the fuzzer on any SystemMemory region access — a harness bug, not an
// acpi bug). Reads return 0; writes are dropped; mapping returns benign zeroed memory.
#[derive(Clone)]
struct FuzzHandler;

impl Handler for FuzzHandler {
    unsafe fn map_physical_region<T>(&self, physical_address: usize, size: usize) -> PhysicalMapping<Self, T> {
        let align = core::mem::align_of::<T>().max(1);
        let bytes = size.max(core::mem::size_of::<T>()).max(align);
        let layout = std::alloc::Layout::from_size_align(bytes, align).unwrap();
        let ptr = std::alloc::alloc_zeroed(layout) as *mut T;
        let virtual_start = NonNull::new(ptr).expect("alloc_zeroed returned null");
        PhysicalMapping { physical_start: physical_address, virtual_start, region_length: size, mapped_length: bytes, handler: self.clone() }
    }
    fn unmap_physical_region<T>(_region: &PhysicalMapping<Self, T>) {}

    fn read_u8(&self, _a: usize) -> u8 { 0 }
    fn read_u16(&self, _a: usize) -> u16 { 0 }
    fn read_u32(&self, _a: usize) -> u32 { 0 }
    fn read_u64(&self, _a: usize) -> u64 { 0 }
    fn write_u8(&self, _a: usize, _v: u8) {}
    fn write_u16(&self, _a: usize, _v: u16) {}
    fn write_u32(&self, _a: usize, _v: u32) {}
    fn write_u64(&self, _a: usize, _v: u64) {}

    fn read_io_u8(&self, _p: u16) -> u8 { 0 }
    fn read_io_u16(&self, _p: u16) -> u16 { 0 }
    fn read_io_u32(&self, _p: u16) -> u32 { 0 }
    fn write_io_u8(&self, _p: u16, _v: u8) {}
    fn write_io_u16(&self, _p: u16, _v: u16) {}
    fn write_io_u32(&self, _p: u16, _v: u32) {}

    fn read_pci_u8(&self, _a: PciAddress, _o: u16) -> u8 { 0 }
    fn read_pci_u16(&self, _a: PciAddress, _o: u16) -> u16 { 0 }
    fn read_pci_u32(&self, _a: PciAddress, _o: u16) -> u32 { 0 }
    fn write_pci_u8(&self, _a: PciAddress, _o: u16, _v: u8) {}
    fn write_pci_u16(&self, _a: PciAddress, _o: u16, _v: u16) {}
    fn write_pci_u32(&self, _a: PciAddress, _o: u16, _v: u32) {}

    fn nanos_since_boot(&self) -> u64 { 1000 }
    fn stall(&self, _us: u64) {}
    fn sleep(&self, _ms: u64) {}

    fn create_mutex(&self) -> Handle { Handle(0) }
    fn acquire(&self, _mutex: Handle, _timeout: u16) -> Result<(), AmlError> { Ok(()) }
    fn release(&self, _mutex: Handle) {}
}
