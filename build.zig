const std = @import("std");
const firmware_upload = @import("firmware_upload");

const AT_MEGA_328P_SIGNATURE = 0x1E950F;
pub fn build(_: *std.Build) !void {}
pub const TargetDevice = struct {
    target: Lazy(std.Build.ResolvedTarget),
    device_path: std.Build.LazyPath,
};
const Device = struct {
    cpu: std.Target.Cpu,
    device_path: []const u8,
};
const CollectDevices = struct {
    step: std.Build.Step,
    target: Generated(std.Build.ResolvedTarget),
    target_query: std.Target.Query,
    device_name: ?[]const u8,
    device_path: std.Build.GeneratedFile,

    flashtool: std.Build.LazyPath,
    doing_upload_step: bool = false,
    fn init(b: *FirmwareBuild) *@This() {
        const self = b.host.allocator.create(@This()) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "collect devices",
                .makeFn = CollectDevices.makeFn,
                .owner = b.host,
            }),
            .target = .{ .step = &self.step },
            .target_query = b.host.standardTargetOptionsQueryOnly(.{}),
            .device_name = b.host.option(
                []const u8,
                "device",
                "The name of the device to upload to",
            ),
            .device_path = .{
                .step = &self.step,
            },
            .flashtool = b.flashtool_bin.getEmittedBin(),
        };
        self.flashtool.addStepDependencies(&self.step);
        return self;
    }
    fn makeFn(step: *std.Build.Step, node: *std.Progress.Node) !void {
        _ =node;
        const self = @fieldParentPtr(@This(), "step", step);
        const argv =&.{self.flashtool.getPath(step.owner)};
        
        const arena = step.owner.allocator;

        try step.handleChildProcUnsupported(null, argv);
        try std.Build.Step.handleVerbose(step.owner, null, argv);

        const result = std.ChildProcess.run(.{
            .allocator = arena,
            .argv = argv,
        }) catch |err| return step.fail("unable to spawn {s}: {s}", .{ argv[0], @errorName(err) });

        if (result.stderr.len > 0) {
            try step.result_error_msgs.append(arena, result.stderr);
        }

        try step.handleChildProcessTerm(result.term, null, argv);

        if (result.stderr.len != 0) {
            return error.MakeFailed;
        }

        var iter = std.mem.splitScalar(u8, result.stdout, '\n');
        var devices = std.ArrayList(Device).init(step.owner.allocator);
        while (iter.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ' ');
            const arch_name = fields.next() orelse return step.fail("malformed device {s}", .{line});
            const cpu_name = fields.next() orelse return step.fail("malformed device {s}", .{line});
            _ = fields.next() orelse return step.fail("malformed device {s}", .{line});
            const device_path = fields.rest();

            const arch: std.Target.Cpu.Arch = std.meta.stringToEnum(std.Target.Cpu.Arch, arch_name) orelse return step.fail("malformed device {s}", .{line});
            const cpu_model = arch.parseCpuModel(cpu_name) catch return step.fail("malformed device {s}", .{line});


            devices.append(.{
                .cpu = cpu_model.toCpu(arch),
                .device_path = device_path,
            }) catch @panic("OOM");
        }
        if (devices.items.len == 0) return step.fail("no devices found", .{});
        const device = devices.items[0];
        self.target.value = step.owner.resolveTargetQuery(self.target_query);
        self.device_path.path = device.device_path;
    }
};


fn Generated(comptime T: type) type {
    return struct {
        step: *std.Build.Step,
        value: ?T = null,
        fn getOutput(self: *const @This()) Lazy(T) {
            return .{ .generated = self };
        }
    };
}

const DeferredCompile = struct {
    step: std.Build.Step,
    options: std.Build.Step.Compile.Options,
    override_target: ?Lazy(std.Build.ResolvedTarget) = null,

    out_bin: std.Build.GeneratedFile,
    fn create(b: *std.Build, options: std.Build.Step.Compile.Options) *@This() {
        const self = b.allocator.create(DeferredCompile) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .compile,
                .name = "zig-build sketch ReleaseSmall",
                .makeFn = DeferredCompile.makeFn,
                .owner = b,
            }),
            .out_bin = .{
                .step = &self.step,
            },
            .options = options,
        };
        return self;
    }
    fn setTarget(self: *DeferredCompile, target: Lazy(std.Build.ResolvedTarget)) void {
        target.addStepDependencies(&self.step);
        self.override_target = target;
    }

    fn makeFn(step: *std.Build.Step, node: *std.Progress.Node) !void {
        const self = @fieldParentPtr(@This(), "step", step);

        if (self.override_target) |target| self.options.root_module.target = target.get().*;
        const sketch_elf_ =  std.Build.Step.Compile.create(step.owner, self.options);
        const bin = sketch_elf_.getEmittedBin();

        std.debug.assert(sketch_elf_.step.dependencies.items.len == 0);
        sketch_elf_.step.make(node) catch |e| {
            step.result_error_msgs.appendSlice(step.owner.allocator , sketch_elf_.step.result_error_msgs.items) catch @panic("OOM");
            step.result_error_bundle = sketch_elf_.step.result_error_bundle;
            return e;
        };

        self.out_bin.path = bin.getPath(step.owner);
    }
    pub fn getEmittedBin(self: *const DeferredCompile) std.Build.LazyPath {
        return .{ .generated = &self.out_bin };
    }
};
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
pub const FirmwareBuild = struct {
    arduino_build: *std.Build,
    host: *std.Build,

    doing_upload_step: bool = false,
    
    flashtool_bin: *std.Build.Step.Compile,
    fn init(b: *std.Build, comptime as_dependency: []const u8) @This() {
        const arduino_build = b.dependency(as_dependency, .{}).builder;
        var flashtool_bin =  arduino_build.addExecutable(.{
            .name = "flashtool",
            .root_source_file = .{ .path = "src/flashtool.zig" },
            .optimize = .ReleaseSafe,
            .target = b.host,
        });
        flashtool_bin.root_module.addImport("firmware_upload", arduino_build.dependency("firmware_upload", .{}).module("flash"));
        return .{
            .host = b,
            .arduino_build = b,
            .flashtool_bin = flashtool_bin,
        };
    }
    pub fn addUpload(b: *FirmwareBuild, target: TargetDevice, firmware: std.Build.LazyPath) void {
        var firmware_upload_exe = b.arduino_build.addRunArtifact(b.flashtool_bin);
        firmware_upload_exe.addArg("write");
        firmware_upload_exe.addFileArg(firmware);
        firmware_upload_exe.addFileArg(target.device_path);
        b.host.step("upload", "Upload firmware images to attached devices")
            .dependOn(&firmware_upload_exe.step);
    }
    pub fn standardTargetDeviceOptions(b: *FirmwareBuild, _: struct {}) TargetDevice {
        const collect = CollectDevices.init(b);
        return .{
            .target = collect.target.getOutput(),
            .device_path = .{ .generated = &collect.device_path },
        };
    }
    pub const ExecutableOptions = struct {
        name: []const u8,
        /// If you want the executable to run on the same computer as the one
        /// building the package, pass the `host` field of the package's `Build`
        /// instance.
        target: ?std.Build.ResolvedTarget = null,
        root_source_file: ?std.Build.LazyPath = null,
        version: ?std.SemanticVersion = null,
        optimize: std.builtin.OptimizeMode = .Debug,
        code_model: std.builtin.CodeModel = .default,
        linkage: ?std.Build.Step.Compile.Linkage = null,
        max_rss: usize = 0,
        link_libc: ?bool = null,
        single_threaded: ?bool = null,
        pic: ?bool = null,
        strip: ?bool = null,
        unwind_tables: ?bool = null,
        omit_frame_pointer: ?bool = null,
        sanitize_thread: ?bool = null,
        error_tracing: ?bool = null,
        use_llvm: ?bool = null,
        use_lld: ?bool = null,
        zig_lib_dir: ?std.Build.LazyPath = null,
        /// Embed a `.manifest` file in the compilation if the object format supports it.
        /// https://learn.microsoft.com/en-us/windows/win32/sbscs/manifest-files-reference
        /// Manifest files must have the extension `.manifest`.
        /// Can be set regardless of target. The `.manifest` file will be ignored
        /// if the target object format does not support embedded manifests.
        win32_manifest: ?std.Build.LazyPath = null,
    };

    pub fn addExecutable(b: *FirmwareBuild, options: ExecutableOptions, deferred: struct { target: ?Lazy(std.Build.ResolvedTarget) }) *DeferredCompile {
        var compile = DeferredCompile.create(b.host, .{
            .name = options.name,
            .root_module = .{
                .root_source_file = options.root_source_file,
                .target = options.target,
                .optimize = options.optimize,
                .link_libc = options.link_libc,
                .single_threaded = options.single_threaded,
                .pic = options.pic,
                .strip = options.strip,
                .unwind_tables = options.unwind_tables,
                .omit_frame_pointer = options.omit_frame_pointer,
                .sanitize_thread = options.sanitize_thread,
                .error_tracing = options.error_tracing,
                .code_model = options.code_model,
            },
            .version = options.version,
            .kind = .exe,
            .linkage = options.linkage,
            .max_rss = options.max_rss,
            .use_llvm = options.use_llvm,
            .use_lld = options.use_lld,
            .zig_lib_dir = options.zig_lib_dir orelse b.host.zig_lib_dir,
            .win32_manifest = options.win32_manifest,
        });
        if (deferred.target) |target| compile.setTarget(target);
        return compile;
    }
};
pub fn buildKit(b: *std.Build, comptime as_dependency: []const u8) FirmwareBuild {
    return FirmwareBuild.init(b, as_dependency);
}