const std = @import("std");
const firmware_upload = @import("firmware_upload");
const serial = firmware_upload.serial;

const AT_MEGA_328P_SIGNATURE = 0x1E950F;
// FIXME: We're missing some configuration of the programmer:
// A bug stopped presenting when I flashed the mcu once with avrdude.


// m328p ext parms
const pagel = 0xd7;
const bs2 = 0xc2;
const eeprom_page = 4;
const reset_disabled = 1;

pub fn main() !void {
    var iterator = try serial.list();
    defer iterator.deinit();
    var alloc = std.heap.GeneralPurposeAllocator(.{}) {};
    const allocator = alloc.allocator();
    const argv = try std.process.argsAlloc(allocator);

    var image_opt: ?[]const u8 = null;
    var port: firmware_upload.ArduinoUnoStkConnection = undefined;
    var device_path: []const u8 = undefined;
    
    if (argv.len == 4 and std.mem.eql(u8, argv[1], "write")) {

        image_opt = std.fs.cwd().readFileAlloc(allocator, argv[2], 1024 * 64) catch |e| {
            std.debug.print("didn't find output", .{});
            return e;
        };
        const handle = std.fs.openFileAbsolute(argv[3], .{ .mode = .read_write }) catch return error.UnexpectedError;
        
        try serial.configureSerialPort(handle, .{
            .baud_rate = 115200,
            .word_size = 8,
            .parity = .none,
            .stop_bits = .one,
            .handshake = .none,
        });
        port = try firmware_upload.ArduinoUnoStkConnection.open(handle);
        device_path = argv[3];
    } else {
        port = while (try iterator.next()) |info| {
            const handle = std.fs.openFileAbsolute(info.file_name, .{ .mode = .read_write }) catch return error.CantOpenAvilableComPort;

            try serial.configureSerialPort(handle, .{
                .baud_rate = 115200,
                .word_size = 8,
                .parity = .none,
                .stop_bits = .one,
                .handshake = .none,
            });
            device_path = info.file_name;
            break firmware_upload.ArduinoUnoStkConnection.open(handle) catch continue;
        } else return error.NoDeviceFound;
    }

    var resp: [64]u8 = undefined;

    try port.send(&.{firmware_upload.Cmnd_STK_READ_SIGN, firmware_upload.Sync_CRC_EOP});
    try port.recv(resp[0..5]);

    if (resp[0] == firmware_upload.Resp_STK_NOSYNC) {
        std.debug.print("lost sync\n", .{});
        try port.drain();
        return;
    } else if (resp[0] != firmware_upload.Resp_STK_INSYNC) {
        std.debug.print("unexpected response\n", .{});
        try port.drain();
        return;
    }
    if (resp[4] != firmware_upload.Resp_STK_OK) {
        std.debug.print("failed to get ok\n", .{});
        try port.drain();
        return;
    }
    const signature: u32 = @intCast(std.mem.readPackedInt(u24, resp[1..4], 0, .big));
    if (signature != AT_MEGA_328P_SIGNATURE) return error.IncompatibleDevice;
    // std.debug.print("Detected ATmega328P\n", .{});
    const cpu = std.Target.avr.cpu.atmega328p.toCpu(std.Target.Cpu.Arch.avr);

    const maj = try port.getparm(firmware_upload.Parm_STK_SW_MAJOR);
    const min = try port.getparm(firmware_upload.Parm_STK_SW_MINOR);
    const extparms: u8 = if ((maj > 1) or ((maj == 1) and (min >= 10))) 4 else 3;
    // std.debug.print("Software version: {}.{}\n", .{maj, min});
    std.io.getStdOut().writer().print("{s} {s} {}.{} {s}\n", .{
        @tagName(cpu.arch),
        cpu.model.name,
        maj,
        min,
        device_path,
    }) catch @panic("OOM");
    if (image_opt) |image| {
        // Only obvious source for this information is avrdude.conf.
        try port.command(&[22]u8{
            firmware_upload.Cmnd_STK_SET_DEVICE,
            0x86, // ATmega328P
            0x00, // Not used
            0x00, // Supports Serial programming
            0x01, // Full Parallel programming
            0x01, // Polling Supported
            0x01, // Self timed
            0x01, // m328 has 1 lock bit
            0x03, // Fuse bytes.

            0xff, // Readback poll value (1)
            0xff, // Readback poll value (2) (yeah Im sorry these values are inscrutable)

            0xff, 0xff, // Readback for eeprom (1)


            0, 128, // 16 bit BE page size - 128 on m328
            0x10, 0x00, // 16 bit BE eeprom size - 1024 on m328

            0x00, 0x00, 0x80, 0x00, // 32 bit BE firmware_upload size - 32k on m328

            firmware_upload.Sync_CRC_EOP
        });
        var setdevicebuf: [7]u8 = .{firmware_upload.Cmnd_STK_SET_DEVICE_EXT, extparms, eeprom_page, pagel, bs2, reset_disabled, firmware_upload.Sync_CRC_EOP};
        setdevicebuf[extparms + 2] = firmware_upload.Sync_CRC_EOP;
        try port.command(setdevicebuf[0..extparms + 3]);


        // const target: f32 = @floatFromInt(try port.getparm(firmware_upload.Parm_STK_VTARGET));
        // const adjust: f32 = @floatFromInt(try port.getparm(firmware_upload.Parm_STK_VADJUST));
        // const osc_pscale: u8 = try port.getparm(firmware_upload.Parm_STK_OSC_PSCALE);
        // const osc_cmatch: f32 = @floatFromInt(try port.getparm(firmware_upload.Parm_STK_OSC_CMATCH));

        // // note: nano uses different xtal
        // // https://github.com/avrdudes/avrdude/blob/a336e47a6e1fe069c45096edaeda1b4841ad7ce5/src/stk500.c#L1583
        // const STK500_XTAL  = 7372800;
        // const SCALE_FACTORS = [_]f32{0.0, 1.0 / 2.0, 1.0 / 16.0, 1.0 / 64.0, 1.0 / 128.0, 1.0 / 256.0, 1.0 / 512.0, 1.0 / 2048.0};
        // const freq = SCALE_FACTORS[osc_pscale] * STK500_XTAL / (osc_cmatch + 1.0);
        // std.debug.print("Target voltage: {d:.2}\n", .{target/10.0});
        // std.debug.print("Adjust voltage: {d:.2}\n", .{adjust/10.0});
        // std.debug.print("Oscillator prescale: {d}\n", .{osc_pscale});
        // std.debug.print("Found frequency: {d}\n", .{freq});

        try port.command(&.{firmware_upload.Cmnd_STK_ENTER_PROGMODE, firmware_upload.Sync_CRC_EOP});
        const page_size = 128;
        var addr: u16 = 0;

        while (addr < image.len) : (addr += page_size) {
            try port.loadaddr(addr / 2);
            var buf = std.mem.zeroes([page_size + 5]u8);
            std.mem.copyForwards(u8, &buf, &.{
                firmware_upload.Cmnd_STK_PROG_PAGE,
                0, 
                page_size,
                'F', // flags
            });
            std.mem.copyForwards(u8, buf[4..], image[addr..@min(addr + page_size, image.len)]);
            buf[4 + page_size] = firmware_upload.Sync_CRC_EOP;
            try port.command(&buf);
            // std.debug.print("Prog page ok\n", .{});
        }
    }
}
