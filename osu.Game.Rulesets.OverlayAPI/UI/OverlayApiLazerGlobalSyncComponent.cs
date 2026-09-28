using System.Diagnostics;
using osu.Framework.Allocation;
using osu.Framework.Bindables;
using osu.Framework.Graphics;
using osu.Framework.Graphics.Sprites;
using osu.Framework.Logging;
using osu.Framework.Platform;
using osu.Framework.Screens;
using osu.Game.Beatmaps;
using osu.Game.Configuration;
using osu.Game.Database;
using osu.Game.Extensions;
using osu.Game.Graphics.Containers;
using osu.Game.Overlays;
using osu.Game.Overlays.Dialog;
using osu.Game.Overlays.Notifications;
using osu.Game.Rulesets.Mods;
using osu.Game.Rulesets.OverlayAPI.Interop;
using osu.Game.Rulesets.Scoring;
using osu.Game.Screens;
using osu.Game.Screens.Edit;
using osu.Game.Screens.Menu;
using osu.Game.Screens.Play;
using osu.Game.Screens.Ranking;
using osu.Game.Screens.Select;
using osu.Game.Skinning;
using OverlayAPI.LazerProtocol;

namespace osu.Game.Rulesets.OverlayAPI.UI;

internal sealed partial class OverlayApiLazerGlobalSyncComponent : Component
{
    private const int status_main_view = 0;
    private const int status_editing = 1;
    private const int status_playing = 2;
    private const int status_song_selection = 5;
    private const int status_results = 7;
    private const int status_beatmap_processing = 19;
    private const double timing_publish_interval = 2;

    private static readonly int s_processId = Process.GetCurrentProcess().Id;

    private static int activeComponent;

    private readonly CancellationTokenSource disposalCts = new();

    private CancellationTokenSource? beatmapMapCts;
    private Task<MappedBeatmap?>? beatmapMapTask;
    private MappedBeatmap? mappedBeatmap;
    private bool isActive;
    private double lastTimingPublishTime;
    private int lastPublishedStatus = int.MinValue;
    private IScreen? currentScreen;
    private Player? boundPlayer;
    private ScoreProcessor? boundScoreProcessor;
    private IDisposable? beatmapOffsetSubscription;
    private double beatmapOffset;
    private bool frontendLoadedNotificationShown;
    private bool riskAcknowledgementDialogShown;
    private Bindable<bool>? showConvertedBeatmaps;
    private bool? showConvertedBeatmapsValueBeforeOverlayApiSongSelect;

    [Resolved(CanBeNull = true)]
    private IBindable<WorkingBeatmap>? workingBeatmap { get; set; }

    [Resolved(CanBeNull = true)]
    private IBindable<RulesetInfo>? ruleset { get; set; }

    [Resolved(CanBeNull = true)]
    private IBindable<IReadOnlyList<Mod>>? selectedMods { get; set; }

    [Resolved(CanBeNull = true)]
    private Storage? storage { get; set; }

    [Resolved(CanBeNull = true)]
    private OsuConfigManager? config { get; set; }

    [Resolved(CanBeNull = true)]
    private RealmAccess? realm { get; set; }

    [Resolved(CanBeNull = true)]
    private OsuGame? osuGame { get; set; }

    [Resolved(CanBeNull = true)]
    private INotificationOverlay? notifications { get; set; }

    [Resolved(CanBeNull = true)]
    private IDialogOverlay? dialogOverlay { get; set; }

    [Resolved(CanBeNull = true)]
    private SkinManager? skinManager { get; set; }

    private LazerSkinInfo[]? lastPublishedSkinInfos;
    private int skinRefreshPending;

    // Ruleset instance cached to avoid CreateInstance() on every CreateState;
    // invalidated when the bound RulesetInfo changes.
    private Ruleset? cachedRuleset;
    private RulesetInfo? cachedRulesetInfo;

    public OverlayApiLazerGlobalSyncComponent()
    {
        AlwaysPresent = true;
    }

    protected override void LoadComplete()
    {
        base.LoadComplete();

        TryActivate();
    }

    protected override void Update()
    {
        base.Update();

        if (!isActive)
        {
            TryActivate();
            return;
        }

        ObserveBeatmapMapTask();
        currentScreen = GetCurrentScreen();
        ApplyOverlayApiSongSelectRestrictions();
        ShowFrontendLoadedNotificationIfNeeded();
        ShowRiskAcknowledgementDialogIfNeeded();
        BindGameplayEvents(currentScreen as Player);

        if (Time.Current - lastTimingPublishTime >= timing_publish_interval)
            PublishTimingState();

        var currentStatus = CurrentStatus();
        if (currentStatus != lastPublishedStatus)
            PublishEventState();
    }

    private void TryActivate()
    {
        if (isActive || workingBeatmap == null || ruleset == null || selectedMods == null || storage == null)
            return;

        if (Interlocked.CompareExchange(ref activeComponent, 1, 0) != 0)
            return;

        isActive = true;
        Logger.Log("Activated OverlayAPI lazer global sync component.");

        workingBeatmap.ValueChanged += OnWorkingBeatmapChanged;
        ruleset.ValueChanged += OnRulesetChanged;
        selectedMods.ValueChanged += OnSelectedModsChanged;

        StartBeatmapMap(workingBeatmap.Value);
        BindBeatmapOffset(workingBeatmap.Value);
        PublishEventState(requestSkinRefresh: true);
        PublishTimingState();
    }

    private void OnWorkingBeatmapChanged(ValueChangedEvent<WorkingBeatmap> beatmap)
    {
        StartBeatmapMap(beatmap.NewValue);
        BindBeatmapOffset(beatmap.NewValue);
        PublishEventState();
        PublishTimingState();
    }

    private void OnRulesetChanged(ValueChangedEvent<RulesetInfo> _)
    {
        cachedRuleset = null;
        cachedRulesetInfo = null;
        PublishEventState();
    }

    private void OnSelectedModsChanged(ValueChangedEvent<IReadOnlyList<Mod>> _) => PublishEventState();

    private void BindBeatmapOffset(WorkingBeatmap beatmap)
    {
        beatmapOffsetSubscription?.Dispose();
        beatmapOffsetSubscription = null;
        beatmapOffset = 0;

        if (realm == null)
        {
            beatmapOffset = SanitiseBeatmapOffset(beatmap.BeatmapInfo.UserSettings.Offset);
            return;
        }

        var beatmapId = beatmap.BeatmapInfo.ID;
        beatmapOffsetSubscription = realm.SubscribeToPropertyChanged(
            r => r.Find<BeatmapInfo>(beatmapId)?.UserSettings,
            settings => settings.Offset,
            OnBeatmapOffsetChanged);
    }

    private void OnBeatmapOffsetChanged(double offset)
    {
        offset = SanitiseBeatmapOffset(offset);
        if (beatmapOffset.Equals(offset))
            return;

        beatmapOffset = offset;
        PublishTimingState();
    }

    private static double SanitiseBeatmapOffset(double offset) => double.IsFinite(offset) ? offset : 0;

    private void StartBeatmapMap(WorkingBeatmap beatmap)
    {
        beatmapMapCts?.Cancel();
        beatmapMapCts?.Dispose();

        mappedBeatmap = null;
        beatmapMapTask = null;

        if (storage == null)
            return;

        beatmapMapCts = CancellationTokenSource.CreateLinkedTokenSource(disposalCts.Token);
        beatmapMapTask = LazerBeatmapFileMapper.CreateAsync(beatmap, storage, OverlayApiLazerIpcClient.Shared.Worker,
            beatmapMapCts.Token);
    }

    private void ObserveBeatmapMapTask()
    {
        if (beatmapMapTask == null || !beatmapMapTask.IsCompleted)
            return;

        var completedTask = beatmapMapTask;
        beatmapMapTask = null;

        if (completedTask.IsCompletedSuccessfully)
        {
            mappedBeatmap = completedTask.Result;
            PublishEventState();
            PublishTimingState();
        }
        else if (!completedTask.IsCanceled && completedTask.Exception != null)
        {
            Logger.Error(completedTask.Exception, "Failed to map lazer beatmap files for OverlayAPI.");
        }
    }

    private void BindGameplayEvents(Player? player)
    {
        // A screen becomes current while it is still loading. GameplayState may already exist at
        // that point, but its ScoreProcessor has not yet received a clock from the drawable tree.
        if (player?.IsLoaded != true || player.GameplayState?.ScoreProcessor?.IsLoaded != true)
            player = null;

        var changed = false;

        if (!ReferenceEquals(boundPlayer, player))
        {
            UnbindScoreProcessor();

            boundPlayer = player;
            changed = true;
        }

        if (player?.GameplayState is { } gameplayState)
        {
            if (boundScoreProcessor == null)
            {
                boundScoreProcessor = gameplayState.ScoreProcessor;
                boundScoreProcessor.Combo.ValueChanged += OnComboChanged;
                changed = true;
            }
        }

        if (changed)
            PublishEventState();
    }

    private void UnbindScoreProcessor()
    {
        if (boundScoreProcessor == null)
            return;

        boundScoreProcessor.Combo.ValueChanged -= OnComboChanged;
        boundScoreProcessor = null;
    }

    private void OnComboChanged(ValueChangedEvent<int> _) => PublishEventState();

    private void ApplyOverlayApiSongSelectRestrictions()
    {
        showConvertedBeatmaps ??= config?.GetBindable<bool>(OsuSetting.ShowConvertedBeatmaps);

        if (showConvertedBeatmaps == null)
            return;

        bool shouldBlockConvertedBeatmaps = currentScreen is SongSelect
                                            && ruleset?.Value.ShortName == OverlayApiRuleset.OVERLAYAPI_SHORT_NAME;

        if (shouldBlockConvertedBeatmaps)
        {
            showConvertedBeatmapsValueBeforeOverlayApiSongSelect ??= showConvertedBeatmaps.Value;

            if (showConvertedBeatmaps.Value)
                showConvertedBeatmaps.Value = false;

            return;
        }

        RestoreShowConvertedBeatmapsSetting();
    }

    private void RestoreShowConvertedBeatmapsSetting()
    {
        if (showConvertedBeatmapsValueBeforeOverlayApiSongSelect == null || showConvertedBeatmaps == null)
            return;

        showConvertedBeatmaps.Value = showConvertedBeatmapsValueBeforeOverlayApiSongSelect.Value;
        showConvertedBeatmapsValueBeforeOverlayApiSongSelect = null;
    }

    private void ShowFrontendLoadedNotificationIfNeeded()
    {
        if (frontendLoadedNotificationShown || currentScreen is not SongSelect || notifications == null)
            return;

        frontendLoadedNotificationShown = true;
        notifications.Post(new SimpleNotification
        {
            Text = "OverlayAPI loaded. Please select another game mode.",
            Icon = FontAwesome.Solid.ExclamationTriangle
        });
    }

    private void ShowRiskAcknowledgementDialogIfNeeded()
    {
        if (riskAcknowledgementDialogShown || currentScreen is not SongSelect || dialogOverlay == null)
            return;

        riskAcknowledgementDialogShown = true;
        dialogOverlay.Push(new OverlayApiRiskAcknowledgementDialog());
    }

    private sealed partial class OverlayApiRiskAcknowledgementDialog : PopupDialog
    {
        public OverlayApiRiskAcknowledgementDialog()
        {
            const string source_url = "https://github.com/Milkitic/osu.Game.Rulesets.OverlayAPI";
            const string external_integrations_url = "https://github.com/ppy/osu/pull/37335";

            Icon = FontAwesome.Solid.ExclamationTriangle;
            HeaderText = "Important Notice";

            var content = new LinkFlowContainer(text => text.Font = text.Font.With(size: 18))
            {
                RelativeSizeAxes = Axes.X,
                AutoSizeAxes = Axes.Y,
                TextAnchor = Anchor.TopLeft,
                Padding = new MarginPadding { Horizontal = 15 }
            };

            content.AddLink("OverlayAPI", source_url);
            content.AddText(
                " uses osu!'s public APIs and reads only the data required to communicate with streaming overlays and other external software.\n\n"
                + "It is designed to be minimally invasive: it does not modify osu!'s behaviour or use reflection.\n\n"
                + "However, it is not a complete, playable ruleset. USE IT AT YOUR OWN RISK.\n"
                + "Once osu!'s official external integrations are ready (");
            content.AddLink("See PR Here", external_integrations_url);
            content.AddText("), this ruleset will be discontinued immediately.");

            MainContent.Add(content);
            Buttons =
            [
                new PopupDialogOkButton
                {
                    Text = "I understand and acknowledge the risks"
                }
            ];
        }
    }

    private void PublishTimingState()
    {
        if (!isActive)
            return;

        lastTimingPublishTime = Time.Current;

        OverlayApiLazerIpcClient.Shared.PublishTiming(new OverlayApiLazerState
        {
            ProcessId = s_processId,
            PlayTime = GetPlayTime(),
            BeatmapOffset = beatmapOffset
        });
    }

    private void PublishEventState(bool requestSkinRefresh = false)
    {
        if (!isActive)
            return;

        var state = CreateState(requestSkinRefresh);
        lastPublishedStatus = state.Status;
        OverlayApiLazerIpcClient.Shared.PublishEvent(state);
    }

    private OverlayApiLazerState CreateState(bool requestSkinRefresh)
    {
        // Skin infos are collected once at activation and re-collected on demand. Collection runs on
        // the dedicated background worker (Realm + File.Exists I/O), never blocking the update thread.
        // PipePublisher resets lastSentState to null on every reconnect, so the cached skins are
        // automatically re-sent to OverlayAPI when it restarts without needing to re-collect here.
        if (requestSkinRefresh)
            RequestSkinRefresh();

        var skinInfos = lastPublishedSkinInfos;

        return new OverlayApiLazerState
        {
            ProcessId = s_processId,
            Status = CurrentStatus(),
            PlayTime = GetPlayTime(),
            BeatmapOffset = beatmapOffset,
            Mods = GetLegacyMods(),
            Combo = boundScoreProcessor?.Combo.Value ?? 0,
            IsReplay = IsReplayPlayback(),
            BeatmapFilename = mappedBeatmap?.Filename,
            BeatmapFiles = mappedBeatmap?.Files ?? [],
            SkinInfos = skinInfos
        };
    }

    private int CurrentStatus()
    {
        return currentScreen switch
        {
            Player => status_playing,
            PlayerLoader => status_beatmap_processing,
            SongSelect => status_song_selection,
            ResultsScreen => status_results,
            Editor => status_editing,
            MainMenu => status_main_view,
            _ => mappedBeatmap == null ? status_main_view : status_song_selection
        };
    }

    private IScreen? GetCurrentScreen()
    {
        var current = osuGame?.ScreenStack?.CurrentScreen;

        while (current is IHasSubScreenStack subScreenStack)
        {
            var nested = subScreenStack.SubScreenStack.CurrentScreen;
            if (nested == null || ReferenceEquals(nested, current))
                break;

            current = nested;
        }

        return current;
    }

    private int GetPlayTime()
    {
        var gameplayTime = boundScoreProcessor?.Clock?.CurrentTime;
        if (gameplayTime is { } time && double.IsFinite(time))
            return (int)Math.Round(time);

        var beatmap = workingBeatmap?.Value;
        if (beatmap?.TrackLoaded == true && double.IsFinite(beatmap.Track.CurrentTime))
            return (int)Math.Round(beatmap.Track.CurrentTime);

        return 0;
    }

    private uint GetLegacyMods()
    {
        try
        {
            if (boundPlayer?.GameplayState is { } gameplayState)
                return unchecked((uint)gameplayState.Ruleset.ConvertToLegacyMods(gameplayState.Mods.ToArray()));

            var currentRulesetInfo = ruleset?.Value;
            if (currentRulesetInfo == null)
                return 0;

            if (cachedRulesetInfo != currentRulesetInfo)
            {
                cachedRulesetInfo = currentRulesetInfo;
                cachedRuleset = currentRulesetInfo.CreateInstance();
            }

            return cachedRuleset == null
                ? 0
                : unchecked((uint)cachedRuleset.ConvertToLegacyMods(selectedMods?.Value?.ToArray() ?? []));
        }
        catch (Exception ex)
        {
            Logger.Log($"Failed to convert mods to legacy mods: {ex.Message}", level: LogLevel.Debug);
            return 0;
        }
    }

    private bool IsReplayPlayback()
    {
        if (boundPlayer is ReplayPlayer or SpectatorPlayer)
            return true;

        return boundPlayer?.GameplayState?.Mods.Any(static mod => mod is ModAutoplay) == true;
    }

    // lazer's built-in "random skin" virtual entry (SkinInfo.RANDOM_SKIN in osu.Game).
    // Excluded from the published skin list since it is not a real selectable skin.
    private static readonly Guid LAZER_RANDOM_SKIN_ID = new Guid("D39DFEFB-477C-4372-B1EA-2BCEA5FB8908");

    /// <summary>
    /// Asynchronously refresh <see cref="lastPublishedSkinInfos"/> on the dedicated background worker.
    /// Coalesces concurrent requests via <see cref="skinRefreshPending"/>.
    /// </summary>
    private void RequestSkinRefresh()
    {
        if (skinManager == null) return;
        if (Interlocked.CompareExchange(ref skinRefreshPending, 1, 0) != 0) return;

        OverlayApiLazerIpcClient.Shared.Worker.Enqueue(_ =>
        {
            try
            {
                var collected = CollectSkinInfos();
                Volatile.Write(ref lastPublishedSkinInfos, collected);

                // The initial event state is published before this background collection finishes,
                // so it contains no skin context. Publish again on the update thread once the data
                // is ready; otherwise a client can remain connected indefinitely without ever
                // receiving SkinInfos when no other event state changes.
                Schedule(() => PublishEventState());
            }
            catch (Exception ex)
            {
                Logger.Error(ex, "Failed to collect lazer skin infos for OverlayAPI.");
            }
            finally
            {
                Interlocked.Exchange(ref skinRefreshPending, 0);
            }

            return Task.CompletedTask;
        });
    }

    private LazerSkinInfo[]? CollectSkinInfos()
    {
        if (skinManager == null)
            return null;

        try
        {
            var skins = skinManager.GetAllUsableSkins();
            var result = new List<LazerSkinInfo>(skins.Count);

            foreach (var live in skins)
            {
                if (live.ID == LAZER_RANDOM_SKIN_ID)
                    continue;

                LazerSkinInfo? mapped = live.PerformRead<LazerSkinInfo?>(info =>
                {
                    if (info.Protected)
                        return null;

                    var files = MapSkinFiles(info);
                    return new LazerSkinInfo
                    {
                        Id = info.ID.ToString(),
                        Name = info.Name ?? string.Empty,
                        Files = files
                    };
                });

                if (mapped != null)
                    result.Add(mapped);
            }

            result.Sort(static (left, right) =>
            {
                var idComparison = string.Compare(left.Id, right.Id, StringComparison.Ordinal);
                return idComparison != 0
                    ? idComparison
                    : string.Compare(left.Name, right.Name, StringComparison.Ordinal);
            });

            return result.ToArray();
        }
        catch (Exception ex)
        {
            Logger.Error(ex, "Failed to collect lazer skin infos for OverlayAPI.");
            return lastPublishedSkinInfos;
        }
    }

    private LazerFile[] MapSkinFiles(SkinInfo skinInfo)
    {
        if (skinInfo.Files == null || skinInfo.Files.Count == 0 || storage == null)
            return [];

        var filesRoot = Path.GetFullPath(storage.GetStorageForDirectory("files").GetFullPath("."));
        var list = new List<LazerFile>(skinInfo.Files.Count);

        foreach (var usage in skinInfo.Files)
        {
            try
            {
                if (!IsRequiredSkinAudioResource(usage.Filename))
                    continue;

                var storagePath = usage.File.GetStoragePath();
                var absolutePath = Path.GetFullPath(Path.Combine(filesRoot, storagePath));

                if (File.Exists(absolutePath))
                {
                    list.Add(new LazerFile
                    {
                        Name = usage.Filename,
                        Path = absolutePath
                    });
                }
            }
            catch
            {
                // Ignore missing / inaccessible files.
            }
        }

        list.Sort(static (left, right) =>
        {
            var nameComparison = string.Compare(left.Name, right.Name, StringComparison.Ordinal);
            return nameComparison != 0
                ? nameComparison
                : string.Compare(left.Path, right.Path, StringComparison.Ordinal);
        });

        return list.ToArray();
    }

    private static bool IsRequiredSkinAudioResource(string filename)
    {
        var extension = Path.GetExtension(filename);
        var isSupportedAudio = extension.Equals(".wav", StringComparison.OrdinalIgnoreCase) ||
                               extension.Equals(".mp3", StringComparison.OrdinalIgnoreCase) ||
                               extension.Equals(".ogg", StringComparison.OrdinalIgnoreCase);
        if (!isSupportedAudio)
            return false;

        var name = Path.GetFileNameWithoutExtension(filename);
        return name.Equals("combobreak", StringComparison.OrdinalIgnoreCase) ||
               name.StartsWith("normal-", StringComparison.OrdinalIgnoreCase) ||
               name.StartsWith("soft-", StringComparison.OrdinalIgnoreCase) ||
               name.StartsWith("drum-", StringComparison.OrdinalIgnoreCase) ||
               name.StartsWith("taiko-", StringComparison.OrdinalIgnoreCase) ||
               name.StartsWith("nightcore-", StringComparison.OrdinalIgnoreCase);
    }

    protected override void Dispose(bool isDisposing)
    {
        if (isDisposing)
        {
            if (isActive)
            {
                workingBeatmap!.ValueChanged -= OnWorkingBeatmapChanged;
                ruleset!.ValueChanged -= OnRulesetChanged;
                selectedMods!.ValueChanged -= OnSelectedModsChanged;

                isActive = false;
                Interlocked.Exchange(ref activeComponent, 0);
            }

            UnbindScoreProcessor();
            beatmapOffsetSubscription?.Dispose();
            beatmapOffsetSubscription = null;
            RestoreShowConvertedBeatmapsSetting();
            beatmapMapCts?.Cancel();
            beatmapMapCts?.Dispose();
            disposalCts.Cancel();
            disposalCts.Dispose();
        }

        base.Dispose(isDisposing);
    }
}
