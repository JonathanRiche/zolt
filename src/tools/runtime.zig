//! Tool execution dispatcher.

const read_tool = @import("read_tool.zig");
const list_dir_tool = @import("list_dir_tool.zig");
const read_file_tool = @import("read_file_tool.zig");
const grep_files_tool = @import("grep_files_tool.zig");
const project_search_tool = @import("project_search_tool.zig");
const apply_patch_tool = @import("apply_patch_tool.zig");
const exec_command_tool = @import("exec_command_tool.zig");
const write_stdin_tool = @import("write_stdin_tool.zig");
const web_search_tool = @import("web_search_tool.zig");
const view_image_tool = @import("view_image_tool.zig");
const skill_tool = @import("skill_tool.zig");
const update_plan_tool = @import("update_plan_tool.zig");

pub fn runReadToolCommand(app: anytype, command_text: []const u8) ![]u8 {
    return read_tool.run(app, command_text);
}

pub fn runListDirToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return list_dir_tool.run(app, payload);
}

pub fn runReadFileToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return read_file_tool.run(app, payload);
}

pub fn runGrepFilesToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return grep_files_tool.run(app, payload);
}

pub fn runProjectSearchToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return project_search_tool.run(app, payload);
}

pub fn runApplyPatchToolPatch(app: anytype, patch_text: []const u8) ![]u8 {
    return apply_patch_tool.run(app, patch_text);
}

pub fn runExecCommandToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return exec_command_tool.run(app, payload);
}

pub fn runWriteStdinToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return write_stdin_tool.run(app, payload);
}

pub fn runWebSearchToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return web_search_tool.run(app, payload);
}

pub fn runViewImageToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return view_image_tool.run(app, payload);
}

pub fn runSkillToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return skill_tool.run(app, payload);
}

pub fn runUpdatePlanToolPayload(app: anytype, payload: []const u8) ![]u8 {
    return update_plan_tool.run(app, payload);
}
