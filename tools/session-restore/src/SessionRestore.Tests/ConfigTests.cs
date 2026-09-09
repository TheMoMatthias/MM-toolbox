using System.Text.Json.Nodes;
using SessionRestore.Core.Config;
using Xunit;

namespace SessionRestore.Tests;

/// <summary>Plan item 2.1 - the config layer.</summary>
public sealed class ConfigTests
{
    // 🔴 THE TEST THAT MAKES THE LENIENT RUNTIME SAFE.
    //
    // SettingDef.Accepts treats "no options declared" as "nothing to check
    // against" rather than "nothing is allowed", because the other reading turned
    // a gap in the generated catalogue into a SILENT RESET of a real setting -
    // railBandsShut arrived with no options, so the operator's own "month,older"
    // was rejected and came back as the default.
    //
    // That leniency is only safe if the gap itself is loud. This is where it is
    // loud. It would have been red before the generator learned to read a Flags
    // list as well as an Options one.
    [Fact]
    public void Every_choice_and_flags_setting_declares_what_it_allows()
    {
        var bad = SettingsCatalog.All
            .Where(s => s.Kind is SettingKind.Choice or SettingKind.Flags)
            .Where(s => s.Options is null || s.Options.Count == 0)
            .Select(s => s.Key)
            .ToList();

        Assert.True(bad.Count == 0,
            "these settings offer a fixed set of values but declare none, so any value would be "
            + "accepted unchecked: " + string.Join(", ", bad));
    }

    [Fact]
    public void Every_setting_can_actually_be_drawn()
    {
        // A settings screen that shows a key name and a box is a JSON editor with
        // a mouse, which is what the operator reported as "it does not work".
        var bad = SettingsCatalog.All
            .Where(s => string.IsNullOrWhiteSpace(s.Label) || string.IsNullOrWhiteSpace(s.Group))
            .Select(s => s.Key)
            .ToList();

        Assert.True(bad.Count == 0, "no label or no group: " + string.Join(", ", bad));
    }

    [Fact]
    public void A_number_outside_its_range_falls_back_to_the_default()
    {
        var def = SettingsCatalog.Find("maxSessions");
        Assert.NotNull(def);
        Assert.True(def.Accepts(30));
        Assert.False(def.Accepts(0));
        Assert.False(def.Accepts(10_000));
        Assert.False(def.Accepts("thirty"));
    }

    [Theory]
    [InlineData("_README", true)]
    [InlineData("//panelScanMaxAgeSeconds", true)]
    [InlineData("", true)]
    [InlineData("maxSessions", false)]
    public void Prose_keys_are_told_apart_from_settings(string key, bool isComment)
        => Assert.Equal(isComment, ConfigFile.IsComment(key));

    [Fact]
    public void The_four_settings_the_old_tool_defaulted_elsewhere_now_have_one_home()
    {
        // These are the keys Get-SRConfigRead does NOT default - the PowerShell
        // sets them inline at the point of use instead, which is the third of the
        // three places a default lived. The catalogue is the only place now.
        foreach (var (key, expected) in new[]
        {
            ("lineSpacing", "normal"),
            ("terminalColour", "on"),
            ("yourGround", "neutral"),
            ("yourInk", "normal"),
        })
        {
            var def = SettingsCatalog.Find(key);
            Assert.NotNull(def);
            Assert.Equal(expected, def.Default);
        }
    }

    [Fact]
    public void A_missing_file_is_every_default_and_not_a_failure()
    {
        // How a fresh machine starts, and how "delete the file to get the
        // defaults back" - which the PowerShell tells the operator - has to work.
        var cfg = ConfigFile.Read(Path.Combine(Path.GetTempPath(), "sr-does-not-exist-" + Guid.NewGuid().ToString("N") + ".json"));

        Assert.Empty(cfg.Keys);
        Assert.Equal(12, cfg.GetInt("maxSessions"));
        Assert.Equal("folded", cfg.GetString("transcriptTools"));
        Assert.True(cfg.GetBool("includeWorktrees"));
    }

    [Fact]
    public void Rendering_keeps_the_operators_prose_and_his_commented_out_keys()
    {
        // 🔴 A READER THAT DROPS WHAT IT DOES NOT RECOGNISE TURNS THE NEXT WRITE
        // INTO A DELETE. The live file carries _README, a //-prefixed key he
        // commented out by hand, and possibly settings from a newer build.
        var path = TempConfig("""
        {
          "_README": ["mine", "not a setting"],
          "//panelScanMaxAgeSeconds": ["why this is off"],
          "maxSessions": 30,
          "somethingANewerBuildAdded": 7
        }
        """);
        try
        {
            var cfg = ConfigFile.Read(path);
            var back = JsonNode.Parse(cfg.Render(new Dictionary<string, object?>()))!.AsObject();

            Assert.Equal(4, back.Count);
            Assert.NotNull(back["_README"]);
            Assert.NotNull(back["//panelScanMaxAgeSeconds"]);
            Assert.Equal(7, back["somethingANewerBuildAdded"]!.GetValue<int>());
            Assert.Contains("somethingANewerBuildAdded", cfg.UnknownKeys);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Rendering_a_change_alters_that_key_and_nothing_else()
    {
        var path = TempConfig("""
        {
          "_README": ["mine"],
          "maxSessions": 30,
          "zoom": 110
        }
        """);
        try
        {
            var cfg = ConfigFile.Read(path);
            var back = JsonNode.Parse(cfg.Render(new Dictionary<string, object?> { ["zoom"] = 125 }))!.AsObject();

            Assert.Equal(125, back["zoom"]!.GetValue<int>());
            Assert.Equal(30, back["maxSessions"]!.GetValue<int>());
            Assert.NotNull(back["_README"]);
            Assert.Equal(3, back.Count);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void A_hand_edited_number_written_as_a_string_still_works()
    {
        // The file is hand-edited and "30" is what a person types. The PowerShell
        // casts and does not care, so refusing here would break a config that
        // works today.
        var path = TempConfig("""{ "maxSessions": "30" }""");
        try
        {
            Assert.Equal(30, ConfigFile.Read(path).GetInt("maxSessions"));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void Unparseable_json_says_what_to_do_about_it()
    {
        var path = TempConfig("{ this is not json ");
        try
        {
            var ex = Assert.Throws<InvalidDataException>(() => ConfigFile.Read(path));
            Assert.Contains("delete the file", ex.Message, StringComparison.Ordinal);
            Assert.Contains(path, ex.Message, StringComparison.Ordinal);
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static string TempConfig(string json)
    {
        var p = Path.Combine(Path.GetTempPath(), "sr-cfg-" + Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(p, json);
        return p;
    }
}
