using System.Text;
using System.Text.Json;
using SessionRestore.Core;
using SessionRestore.Core.Registry;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.7 - the registry write.</summary>
/// <remarks>
/// 🔴 A REGISTRY-OVERWRITE BUG IN THIS REPO'S HISTORY COST 210 CONVERSATIONS.
/// Every test here works in its own temporary directory and removes it; none of
/// them can reach the operator's file, because <see cref="RegistryTarget"/> has
/// no factory that names it.
/// </remarks>
public sealed class RegistryWriteTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "sr-wtest-" + Guid.NewGuid().ToString("N"));

    public RegistryWriteTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    // -----------------------------------------------------------------
    // The guard.
    // -----------------------------------------------------------------

    [Fact]
    public void A_session_that_never_read_the_file_may_write_it()
    {
        // There is nothing to be stale against.
        Assert.True(SaveDecision.For(null, "anything", true).Allowed);
        Assert.True(SaveDecision.For("", "anything", true).Allowed);
    }

    [Fact]
    public void A_check_that_cannot_tell_must_not_permit()
    {
        // 🔴 THIS USED TO BE `if ($now -and $now -ne $stamp)`, so an EMPTY $now
        // fell straight through and the save went ahead - and empty is exactly
        // what the stamp returns when it cannot see the file. Having a stamp at
        // all means this session read a registry, so failing to stamp one now is
        // not evidence that nothing changed; it is evidence that the question
        // could not be answered.
        Assert.Equal(SaveVerdict.RefuseUnreadable, SaveDecision.For("a", "", fileExists: true).Verdict);

        // 🪤 AND THE ONE CASE WHERE EMPTY REALLY DOES MEAN "NOTHING TO CLOBBER"
        // is a file that is genuinely gone - asked separately, never inferred
        // from the same silence.
        Assert.True(SaveDecision.For("a", "", fileExists: false).Allowed);
    }

    [Fact]
    public void A_held_file_and_a_changed_file_are_different_refusals()
    {
        // The operator can act on each differently: try again, versus Rescan
        // first. Collapsing them into "could not save" is what makes people
        // force it.
        var held = SaveDecision.For("a", RegistryStamp.Unhashed, true);
        var changed = SaveDecision.For("a", "b", true);

        Assert.Equal(SaveVerdict.RefuseHeld, held.Verdict);
        Assert.Equal(SaveVerdict.RefuseChanged, changed.Verdict);
        Assert.Contains("something else has it open", held.Why, StringComparison.Ordinal);
        Assert.Contains("Rescan", changed.Why, StringComparison.Ordinal);
    }

    [Fact]
    public void Force_overrides_every_refusal()
    {
        // For the caller that has already told the operator and been told to go
        // ahead.
        foreach (var now in new[] { "b", RegistryStamp.Unhashed, "" })
        {
            Assert.True(SaveDecision.For("a", now, true, force: true).Allowed);
        }
    }

    [Fact]
    public void Two_stamps_differing_only_in_case_are_two_different_files_here()
    {
        // 🔴 A DELIBERATE, DOCUMENTED DIVERGENCE FROM THE SHIPPED POWERSHELL.
        // Its `-ne` on strings is case-insensitive, so it calls these equal and
        // ALLOWS the save; this refuses. It cannot occur - a stamp is
        // length|ticks|SHA256HEX and the hex always comes back upper case from
        // the same function - so neither behaviour is reachable from the tool.
        // Being the stricter of the two is the right side to err on for the
        // check that protects 210 conversations, and matching the quirk would
        // mean writing a knowingly weaker guard.
        Assert.Equal(SaveVerdict.RefuseChanged, SaveDecision.For("A-STAMP", "a-stamp", true).Verdict);
    }

    // -----------------------------------------------------------------
    // The target.
    // -----------------------------------------------------------------

    [Fact]
    public void The_live_registry_cannot_be_named_however_it_is_spelled()
    {
        // 🪤 A GUARD THAT COMPARED THE STRING IT WAS HANDED would wave all but
        // the first of these through. They are all the same file.
        var reg = ToolPaths.Registry;
        var dir = Path.GetDirectoryName(reg)!;
        var leaf = Path.GetFileName(reg);

        foreach (var p in new[]
        {
            reg,
            reg.ToUpperInvariant(),
            reg.ToLowerInvariant(),
            Path.Combine(dir, ".", leaf),
            Path.Combine(dir, "lib", "..", leaf),
        })
        {
            Assert.Null(RegistryTarget.ForCopy(p, out var why));
            Assert.Contains("refusing to write", why, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void The_live_config_cannot_be_named_either()
    {
        Assert.Null(RegistryTarget.ForCopy(ToolPaths.Config, out var why));
        Assert.Contains("live config", why, StringComparison.Ordinal);
    }

    [Fact]
    public void An_ordinary_copy_is_allowed_and_carries_its_full_path()
    {
        var t = RegistryTarget.ForCopy(Path.Combine(_dir, ".", "copy.json"), out var why);

        Assert.NotNull(t);
        Assert.Equal(string.Empty, why);
        Assert.Equal(Path.Combine(_dir, "copy.json"), t!.Path);
    }

    // -----------------------------------------------------------------
    // The stamp.
    // -----------------------------------------------------------------

    [Fact]
    public void A_missing_file_and_an_unreadable_one_are_different_answers()
    {
        // 🔴 The save guard treats them oppositely, so collapsing them is what
        // let a save go through against a registry it had failed to read.
        var missing = Path.Combine(_dir, "not-here.json");
        Assert.Equal(string.Empty, RegistryStamp.Of(missing));

        var held = Path.Combine(_dir, "held.json");
        File.WriteAllText(held, "{}");
        using (var _ = new FileStream(held, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            Assert.Equal(RegistryStamp.Unhashed, RegistryStamp.Of(held));
        }

        // Released again, it stamps normally.
        Assert.Equal(3, RegistryStamp.Of(held).Split('|').Length);
    }

    [Fact]
    public void One_changed_byte_changes_the_stamp()
    {
        var p = Path.Combine(_dir, "s.json");
        File.WriteAllText(p, "{\"version\":3}");
        var before = RegistryStamp.Of(p);

        File.WriteAllText(p, "{\"version\":4}");
        Assert.NotEqual(before, RegistryStamp.Of(p));
    }

    // -----------------------------------------------------------------
    // The write.
    // -----------------------------------------------------------------

    [Fact]
    public void A_blocked_destination_is_reported_and_leaves_the_file_intact()
    {
        // 🔴 THE DEFECT THE POWERSHELL HAD. Set-Content and Move-Item report a
        // held file as a NON-TERMINATING error, so the write never happened, the
        // function returned normally, and the caller re-stamped against the OLD
        // file - leaving its staleness check agreeing with a save that never
        // took place. The operator's ticks were gone with nothing said.
        var p = Path.Combine(_dir, "blocked.json");
        File.WriteAllText(p, "{\"version\":3,\"directories\":[]}");
        var before = File.ReadAllBytes(p);
        var t = RegistryTarget.ForCopy(p, out _)!;

        SaveResult r;
        using (var _ = new FileStream(p, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            r = RegistryWriter.Save(new SessionRegistry(), t, readStamp: null);
        }

        Assert.False(r.Written);
        Assert.NotNull(r.Error);
        Assert.Contains("could not be saved", r.Error!, StringComparison.Ordinal);
        Assert.Equal(before, File.ReadAllBytes(p));

        // 🪤 AND NO .tmp LEFT BEHIND. The next write targets the same name, and a
        // stale one that cannot be overwritten fails every save from then on.
        Assert.False(File.Exists(p + ".tmp"));
    }

    [Fact]
    public void A_refused_save_hands_back_the_stamp_that_was_read()
    {
        // 🔴 A refusal must leave the caller's staleness check exactly as it was,
        // or the next save would believe it was up to date with a file it never
        // saw.
        var p = Path.Combine(_dir, "r.json");
        File.WriteAllText(p, "{\"version\":3,\"directories\":[]}");
        var t = RegistryTarget.ForCopy(p, out _)!;

        var r = RegistryWriter.Save(new SessionRegistry(), t, readStamp: "a-stamp-from-before");

        Assert.False(r.Written);
        Assert.Equal(SaveVerdict.RefuseChanged, r.Decision.Verdict);
        Assert.Equal("a-stamp-from-before", r.Stamp);
    }

    [Fact]
    public void A_written_registry_is_utf8_with_a_bom_and_stamps_to_what_it_returned()
    {
        // 🔑 The stamp is a hash of the BYTES, and the file on disk has a BOM -
        // measured. A writer that dropped it would make every other reader's
        // stamp disagree.
        var p = Path.Combine(_dir, "w.json");
        var t = RegistryTarget.ForCopy(p, out _)!;

        var r = RegistryWriter.Save(new SessionRegistry(), t, readStamp: null);

        Assert.True(r.Written);
        Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF }, File.ReadAllBytes(p)[..3]);
        Assert.Equal(RegistryStamp.Of(p), r.Stamp);
    }

    [Fact]
    public void A_field_this_build_does_not_model_survives_a_write()
    {
        // 🔴 THIS IS HOW A TICK DISAPPEARS. A writer that emitted only what it
        // models would silently destroy anything a newer build added - and
        // `prefs`, the whole per-conversation control plane, lives exactly there.
        var p = Path.Combine(_dir, "extra.json");
        var reg = new SessionRegistry
        {
            Directories =
            {
                new RegistryDirectory
                {
                    Path = @"C:\x",
                    Enabled = true,
                    Sessions =
                    {
                        new RegistrySession
                        {
                            SessionId = "abc",
                            Enabled = true,
                            Extra = new Dictionary<string, JsonElement>(StringComparer.Ordinal)
                            {
                                ["prefs"] = JsonDocument.Parse("""{"model":"claude-opus-5"}""").RootElement.Clone(),
                                ["fromTheFuture"] = JsonDocument.Parse("\"keep me\"").RootElement.Clone(),
                            },
                        },
                    },
                },
            },
        };

        Assert.True(RegistryWriter.Save(reg, RegistryTarget.ForCopy(p, out _)!, null).Written);

        var back = SessionRegistry.Read(p);
        var s = Assert.Single(back.AllSessions);
        Assert.NotNull(s.Extra);
        Assert.Equal("claude-opus-5", s.Extra!["prefs"].GetProperty("model").GetString());
        Assert.Equal("keep me", s.Extra["fromTheFuture"].GetString());
    }

    [Fact]
    public void A_non_ascii_title_is_written_as_itself_and_not_as_escapes()
    {
        // 🔴 The default encoder escapes non-ASCII to \uXXXX, so a path or a
        // title with an umlaut would come back correct and change every byte of
        // its row on the first write - turning one save into a whole-file
        // rewrite and making any diff useless.
        var p = Path.Combine(_dir, "u.json");
        var reg = new SessionRegistry
        {
            Directories = { new RegistryDirectory { Path = @"C:\Über\Straße", Enabled = true } },
        };

        Assert.True(RegistryWriter.Save(reg, RegistryTarget.ForCopy(p, out _)!, null).Written);

        var text = File.ReadAllText(p, Encoding.UTF8);
        Assert.Contains(@"C:\\Über\\Straße", text, StringComparison.Ordinal);
        Assert.DoesNotContain(@"\u00DC", text, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void The_lock_name_is_the_one_the_shipped_tool_uses()
    {
        // 🔴 IT MUST STAY IDENTICAL WHILE BOTH TOOLS EXIST. Two different names
        // is two locks and no mutual exclusion at all - and during the cutover
        // both will be running against one file.
        var src = File.ReadAllText(Path.Combine(ToolPaths.Lib, "_common.ps1"));
        Assert.Contains("'" + RegistryLock.Name + "'", src, StringComparison.Ordinal);
    }

    [Fact]
    public void The_lock_is_re_entrant_on_one_thread()
    {
        // 🔑 Which is what lets a whole read-modify-write hold it while the save
        // takes it again inside.
        var inner = RegistryLock.Run(
            () => RegistryLock.Run(() => 42, out var innerHeld) + (innerHeld ? 0 : 1000),
            out var outerHeld);

        Assert.True(outerHeld);
        Assert.Equal(42, inner);
    }
}
