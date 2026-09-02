//! Stable request metadata shared by inference consumers.

pub const InvocationRole = enum {
    chat,
    author_room,
    discovery,
    structure_director,
    passage_writer,
    change_extractor,
    local_checker,
    boundary_auditor,
    revision_coordinator,
    suggestion_generator,
    import_reconciler,
};

pub const InvocationBudget = struct {
    input_target: u32,
    input_hard_ceiling: u32,
    output_reserve: u32,
    timeout_ms: u32,
};
