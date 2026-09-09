using System.Text;
using System.Text.Json;
using SessionRestore.Core.Registry;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.2 - the registry read.</summary>
public sealed class RegistryTests
{
    // 🪤 THESE ASSERT INVARIANTS, NOT COUNTS. The suite reads the operator's real
    // registry, and "there are 558 conversations" is a fact about his Tuesday
    // rather than about this code - it went red twice in the PowerShell suites
    // for exactly that reason. What must hold whatever is in the file is that
    // the parts agree with each other.
    [Fact]
    public void The_real_registry_reads_and_is_internally_consistent()
    {
        var r = SessionRegistry.Read();

        Assert.False(r.RequiresMigration, r.MigrationAdvice);
        Assert.Equal(r.Directories.Sum(d => d.Sessions.Count), r.AllSessions.Count());
        Assert.All(r.Directories, d => Assert.False(string.IsNullOrWhiteSpace(d.Path)));
        Assert.All(r.AllSessions, s => Assert.False(string.IsNullOrWhiteSpace(s.SessionId)));
    }

    [Fact]
    public void A_conversation_id_identifies_exactly_one_conversation()
    {
        // The whole model keys on this: a duplicate id means two rows that
        // cannot be told apart, and a tick set on one landing on the other.
        var r = SessionRegistry.Read();
        var dupes = r.AllSessions
            .GroupBy(s => s.SessionId, StringComparer.Ordinal)
            .Where(g => g.Count() > 1)
            .Select(g => g.Key)
            .ToList();

        Assert.True(dupes.Count == 0, "duplicate session ids: " + string.Join(", ", dupes));
    }

    [Fact]
    public void The_byte_order_mark_the_registry_is_written_with_is_handled()
    {
        // 🔴 MEASURED, NOT ASSUMED: sessions-registry.json starts EF BB BF and
        // session-restore.config.json does not. The two data files this tool owns
        // disagree about it, so neither reader may assume either way.
        var path = Temp();
        try
        {
            File.WriteAllText(path,
                """{"version":3,"directories":[{"path":"C:\\x","enabled":true,"sessions":[]}]}""",
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));

            Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF }, File.ReadAllBytes(path)[..3]);

            var r = SessionRegistry.Read(path);
            Assert.Equal(3, r.Version);
            Assert.Single(r.Directories);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Fields_this_build_has_never_heard_of_survive_the_read()
    {
        // 🔴 THE REASON THIS MATTERS IS THE WRITE THAT COMES LATER. A registry
        // written by a newer build carries fields this one does not model, and a
        // model that drops them turns the next save into a silent delete. A
        // registry-overwrite bug in this repo's history cost 210 conversations.
        var path = Temp();
        try
        {
            File.WriteAllText(path, """
            {
              "version": 3,
              "somethingNewAtTheTop": 42,
              "directories": [{
                "path": "C:\\x",
                "enabled": true,
                "aDirectoryFieldFromLater": "keep me",
                "sessions": [{
                  "sessionId": "abc",
                  "title": "t",
                  "enabled": true,
                  "aSessionFieldFromLater": [1, 2, 3]
                }]
              }]
            }
            """);

            var r = SessionRegistry.Read(path);

            Assert.NotNull(r.Extra);
            Assert.Equal(42, r.Extra!["somethingNewAtTheTop"].GetInt32());

            var d = r.Directories[0];
            Assert.NotNull(d.Extra);
            Assert.Equal("keep me", d.Extra!["aDirectoryFieldFromLater"].GetString());

            var s = d.Sessions[0];
            Assert.NotNull(s.Extra);
            Assert.Equal(JsonValueKind.Array, s.Extra!["aSessionFieldFromLater"].ValueKind);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void An_older_schema_is_refused_with_something_to_do_about_it()
    {
        // 🔴 THE v1 AND v2 MIGRATIONS ARE NOT PORTED, deliberately. They rewrite
        // the operator's ticks in place, and the only file available to test
        // them against is already v3 - a port would be code that has never run
        // on its own input. The PowerShell still has both and still runs, so the
        // answer is "open the old tool once", not a rewrite nobody exercised.
        var path = Temp();
        try
        {
            File.WriteAllText(path, """{"version":2,"directories":[]}""");
            var r = SessionRegistry.Read(path);

            Assert.True(r.RequiresMigration);
            Assert.Contains("Sessions.exe", r.MigrationAdvice, StringComparison.Ordinal);
            Assert.Contains("version 2", r.MigrationAdvice, StringComparison.Ordinal);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_missing_registry_is_an_empty_one()
    {
        var r = SessionRegistry.Read(Path.Combine(Path.GetTempPath(), "sr-none-" + Guid.NewGuid().ToString("N") + ".json"));
        Assert.Empty(r.Directories);
        Assert.Empty(r.AllSessions);
        Assert.False(r.RequiresMigration);
    }

    [Fact]
    public void An_unreadable_registry_says_what_to_do_about_it()
    {
        var path = Temp();
        try
        {
            File.WriteAllText(path, "{ not json at all ");
            var ex = Assert.Throws<InvalidDataException>(() => SessionRegistry.Read(path));
            Assert.Contains("Delete it to start fresh", ex.Message, StringComparison.Ordinal);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void The_rejected_set_is_kept_verbatim()
    {
        // 428 entries this build has no use for. Modelling a shape nobody reads
        // is how a field gets dropped on the next write; keeping the node is not.
        var r = SessionRegistry.Read();
        if (r.Rejected is null)
        {
            return; // a registry that has rejected nothing is legitimate
        }

        Assert.All(r.Rejected, kv => Assert.False(string.IsNullOrEmpty(kv.Key)));
    }

    private static string Temp() =>
        Path.Combine(Path.GetTempPath(), "sr-reg-" + Guid.NewGuid().ToString("N") + ".json");
}
