//! Backward-compatible shim.

const tool = @import("tools/patch_tool.zig");

pub const ApplyStats = tool.ApplyStats;
pub const applyCodexPatch = tool.applyCodexPatch;
