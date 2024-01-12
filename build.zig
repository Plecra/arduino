const std = @import("std");
const firmware_upload = @import("firmware_upload");

pub fn build(b: *std.Build) void {
    _= b;
    
    // var iterator = try firmware_upload.serial.list();
    // defer iterator.deinit();
    // // var alloc = std.heap.GeneralPurposeAllocator(.{}) {};
    // // const allocator = alloc.allocator();

    // // const image = try std.fs.cwd().readFileAlloc(allocator, "../arduinodemo/zig-out/bin/main.bin", 1024 * 64);

    // var port = while (try iterator.next()) |info| {
    //     const port = std.fs.openFileAbsolute(info.file_name, .{ .mode = .read_write }) catch return error.UnexpectedError;

    //     try firmware_upload.serial.configureSerialPort(port, .{
    //         .baud_rate = 115200,
    //         .word_size = 8,
    //         .parity = .none,
    //         .stop_bits = .one,
    //         .handshake = .none,
    //     });
    //     break firmware_upload.ArduinoUnoStkConnection.open(port) catch continue;
    // } else return error.NoDeviceFound;
    // var resp: [64]u8 = undefined;

    // try port.send(&.{firmware_upload.Cmnd_STK_READ_SIGN, firmware_upload.Sync_CRC_EOP});
    // try port.recv(resp[0..5]);

    // if (resp[0] == firmware_upload.Resp_STK_NOSYNC) {
    //     std.debug.print("lost sync\n", .{});
    //     try port.drain();
    //     return;
    // } else if (resp[0] != firmware_upload.Resp_STK_INSYNC) {
    //     std.debug.print("unexpected response\n", .{});
    //     try port.drain();
    //     return;
    // }
    // if (resp[4] != firmware_upload.Resp_STK_OK) {
    //     std.debug.print("failed to get ok\n", .{});
    //     try port.drain();
    //     return;
    // }
    // const signature: u32 = @intCast(std.mem.readPackedInt(u24, resp[1..4], 0, .big));
    // if (signature != AT_MEGA_328P_SIGNATURE) return error.IncompatibleDevice;
    // std.debug.print("Detected ATmega328P\n", .{});
}
const AT_MEGA_328P_SIGNATURE = 0x1E950F;


    // const target = std.Build.resolveTargetQuery(b, .{
    //     .cpu_arch = .avr,
    //     .os_tag = .freestanding,
    //     .abi = .eabi,

    //     // TODO: Directly output to .bin when it's implemented
    //     // .ofmt = .raw,

    //     // .cpu_features_add = featureSet(&.{std.Target.avr.Feature.jmpcall}),
    //     .cpu_features_add = std.Target.avr.cpu.atmega328p.features,
    // });
pub const TargetDevice = struct {
    target: Lazy(std.Build.ResolvedTarget),
};
const CollectDevices = struct {
    step: std.Build.Step,
    target: Generated(std.Build.ResolvedTarget),
    resolved_target: std.Build.ResolvedTarget,
    device_name: ?[]const u8,

    // flashtool: std.Build.LazyPath,
    fn init(b: *std.Build) *@This() {
        const self = b.allocator.create(@This()) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "collect devices",
                .makeFn = CollectDevices.makeFn,
                .owner = b,
            }),
            .target = .{ .step = &self.step },
            .resolved_target = b.standardTargetOptions(.{}),
            // .flashtool = flashtool(b),
            .device_name = b.option(
                []const u8,
                "device",
                "The name of the device to upload to",
            ),
        };
        // self.flashtool.addStepDependencies(&self.step);
        return self;
    }
    fn makeFn(step: *std.Build.Step, node: *std.Progress.Node) !void {
        _ =node;
        const self = @fieldParentPtr(@This(), "step", step);
        self.target.value = self.resolved_target;
        // try step.evalChildProcess(&.{self.flashtool.getPath(step.owner)});
    }
};
pub fn standardTargetDeviceOptions(b: *std.Build, _: struct {}) TargetDevice {
    const collect = CollectDevices.init(b);
    return .{
        .target = collect.target.getOutput(),
    };
}

pub fn addUpload(b: *std.Build, _: TargetDevice, _: std.Build.LazyPath) void {
    const upload = b.step("upload", "Upload firmware images to attached devices");
    _ = upload;
}
var FlashToolBinaries = std.AutoHashMapUnmanaged(*std.Build, *std.Build.Step.Compile) {};
fn flashtool(b: *std.Build) std.Build.LazyPath {
    const slot = FlashToolBinaries.getOrPut(b.allocator, b) catch @panic("OOM");
    if (!slot.found_existing) {
        
        slot.key_ptr.* = b;
        slot.value_ptr.* = b.addExecutable(.{
            .name = "flashtool",
            .root_source_file = .{ .path = "src/flashtool.zig" },
            .optimize = .ReleaseSafe,
            .target = b.host,
        });
    }
    return slot.value_ptr.*.getEmittedBin();
}

fn Generated(comptime T: type) type {
    return struct {
        step: *std.Build.Step,
        value: ?T = null,
        fn getOutput(self: *const @This()) Lazy(T) {
            return .{ .generated = self };
        }
    };
}
pub fn Lazy(comptime T: type) type {
    return union(enum) {
        immediate: T,
        generated: *const Generated(T),

        pub fn get(self: *const @This()) *const T {
            switch (self.*) {
                .immediate => return &self.immediate,
                .generated => return &self.generated.value.?,
            }
        }
        pub fn addStepDependencies(self: *const @This(), step: *std.Build.Step) void {
            switch (self.*) {
                .immediate => {},
                .generated => step.dependOn(self.generated.step),
            }
        }
    };
}