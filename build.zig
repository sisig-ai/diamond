const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const model2vec = b.dependency("model2vec", .{
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "model2vec", .module = model2vec.module("model2vec") },
        },
    });
    root_mod.addAnonymousImport("potion_tokenizer", .{
        .root_source_file = b.path("assets/potion-base-8M/tokenizer.json"),
    });
    root_mod.addAnonymousImport("potion_model", .{
        .root_source_file = b.path("assets/potion-base-8M/model.i8.safetensors"),
    });

    const exe = b.addExecutable(.{
        .name = "diamond",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "model2vec", .module = model2vec.module("model2vec") },
        },
    });
    test_mod.addAnonymousImport("potion_tokenizer", .{
        .root_source_file = b.path("assets/potion-base-8M/tokenizer.json"),
    });
    test_mod.addAnonymousImport("potion_model", .{
        .root_source_file = b.path("assets/potion-base-8M/model.i8.safetensors"),
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run unit and CLI tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_cli_tests.step);
}
