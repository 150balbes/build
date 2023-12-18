echo "Start Add dtb EFI .........."
setenv efi_fdtfile "dtb/nvidia/tegra210-p3450-0000.dtb"
run load_efi_dtb
setenv kernel_addr_r "0x86000000"
echo "Stop Add dtb EFI .........."
