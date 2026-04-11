pub const db = @import("db.zig");
pub const migrations = @import("migrations.zig");
pub const namespaces = @import("namespaces.zig");
pub const sessions = @import("sessions.zig");
pub const messages = @import("messages.zig");
pub const projects = @import("projects.zig");
pub const summaries = @import("summaries.zig");
pub const knowledge = @import("knowledge.zig");

pub const Database = db.Database;
pub const Connection = db.Connection;
pub const Statement = db.Statement;
pub const Namespaces = namespaces.Namespaces;
pub const SessionStore = sessions.SessionStore;
pub const SessionInfo = sessions.SessionInfo;
pub const MessageStore = messages.MessageStore;
pub const MessageInfo = messages.MessageInfo;
pub const ProjectStore = projects.ProjectStore;
pub const ProjectInfo = projects.ProjectInfo;
pub const ProjectSummary = projects.ProjectSummary;
pub const RollingContext = projects.RollingContext;
pub const SummaryStore = summaries.SummaryStore;
pub const SummaryInfo = summaries.SummaryInfo;
pub const KnowledgeStore = knowledge.KnowledgeStore;
pub const KnowledgeEntry = knowledge.KnowledgeEntry;

pub const skills = @import("skills.zig");
pub const SkillStore = skills.SkillStore;
pub const Skill = skills.Skill;

pub const embeddings = @import("embeddings.zig");
pub const EmbeddingStore = embeddings.EmbeddingStore;

/// Run database migrations.
pub fn runMigrations(conn: *Connection) !void {
    return migrations.runMigrations(conn);
}
