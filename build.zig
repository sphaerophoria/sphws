const std = @import("std");

// FIXME: Export sphws as proper module

pub fn build(b: *std.Build) !void {
    const sphtud_dep = b.dependency("sphtud", .{});
    const sphtud = sphtud_dep.module("sphtud");
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("sphws", .{
        .root_source_file = b.path("src/sphws.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "event_loop_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/event_loop_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("sphtud", sphtud);

    const blocking_exe = b.addExecutable(.{
        .name = "blocking_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blocking_example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);
    b.installArtifact(blocking_exe);
}
