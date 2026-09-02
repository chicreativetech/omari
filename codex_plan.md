• The current tree confirms the central issue is still present: each nearby thumbnail is
  live, wrapped in an always-enabled mipmapped layer. I’m also checking how an opening
  target can be identified early enough; the existing dive indices are assigned too late to
  solve opening-resolution quality by themselves.

• Ran 8 commands · ctrl + t to view transcript

───────────────────────────────────────────────────────────────────────────────────────────

• One refinement to the earlier proposals: on slow hardware, refreshing every off-screen
  window on every open is still unnecessary work. The better policy is snapshot-only plus
  prioritized, lazy refresh—target first, visible content after the opening transition, and
  distant content only when it enters a prefetch margin. That preserves old GPU textures
  and avoids turning a large workspace set into a background capture batch.

• Explored
  └ Read OmariOverview.qml, KineticScroll.qml, README.md

───────────────────────────────────────────────────────────────────────────────────────────

• The best design is a single snapshot-first renderer: no Auto mode, hardware detector,
  live-mode UI, or CPU bitmap path. Omari should preserve its already-mapped surface for
  instant response, then animate cached GPU textures while capture work is paced outside
  the motion-critical path.

  ## Revised technical conclusion

  The current bottleneck is confirmed in the working tree:

  - Nearby windows remain live at OmariOverview.qml:3474.
  - Every capture sits inside an always-enabled mipmapped layer at OmariOverview.qml:3431.
  - In Quickshell 0.3.1, each live frame marks the view dirty, repaints that layer,
    rebuilds its mipmaps, and requests another frame.

  That turns every visible window into a continuous rendering loop. Snapshot mode changes
  scrolling and zooming into mostly cached-texture transforms—the closest Omari can get to
  Niri’s animation path without being part of the compositor.

  Two refinements improve the earlier proposals:

  - Do not refresh every distant window on every open. Refresh lazily as content approaches
    the viewport.

  - Defer assigning captureSource to never-seen thumbnails. Quickshell automatically
    requests a frame when a capture context is created, even with live: false; creating
    every context immediately would still cause an initial capture burst.

  ## Implementation plan

  ### 1. Establish the baseline

  Profile the current implementation with QSG_RENDER_TIMING=1 during:

  - Warm overview opening and diving.
  - Continuous horizontal and vertical gestures.
  - Momentum and snap animations.
  - Animated window content, such as video or terminal output.
  - Four to ten workspaces with several windows each.

  Record frame intervals, long hitches, idle redraw activity, and zoom-target image
  quality. Use the existing frame tracing only for transition sequencing, not as a
  permanent adaptive profiler.

  ### 2. Replace live streams with scheduled snapshots

  Make every ScreencopyView permanently live: false.

  Add a central, frame-aligned capture scheduler. Use FrameAnimation, not a wall-clock
  Timer, and begin with a limit of one capture request per rendered frame.

   Priority    Capture policy
  ━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   0           Opening or dive target
  ──────────  ──────────────────────────────────────────────────────
   1           Visible thumbnail with no existing picture
  ──────────  ──────────────────────────────────────────────────────
   2           Visible stale thumbnail after opening motion settles
  ──────────  ──────────────────────────────────────────────────────
   3           Thumbnail entering the existing prefetch margins

  Additional rules:

  - Keep the previous texture visible while requesting a replacement.
  - Never clear or reassign captureSource during an ordinary refresh.
  - Assign captureSource lazily the first time a thumbnail becomes eligible; retain it
    afterward.

  - Track one request per thumbnail per overview generation so bindings cannot enqueue
    duplicates.

  - Pause low-priority requests while zooming or either scroll axis is moving. Resume
    gradually—never as a settle-frame burst.

  - Do not depend on capture completion. Quickshell exposes no useful refresh-completion
    notification, and repeated requests while one is pending are ignored.

  - Keep the bounded recovery timer at OmariOverview.qml:3551, but apply the same
    visibility and priority rules to recovery.

  The existing nearRow, vertical margin, and render margin remain useful as snapshot-
  prefetch and recovery eligibility. Rename liveMargin to reflect its new purpose rather
  than deleting the mechanism.

  ### 3. Preserve Omari’s instant opening

  Keep the permanently mapped surface at OmariOverview.qml:2555. That is what provides the
  “snappy like Omarchy” half of the design.

  On summon:

  1. Display the retained target snapshot immediately.
  2. Request one fresh target snapshot.
  3. Begin the opening gesture without waiting for freshness if an old picture exists.
  4. Refresh the other visible thumbnails only after opening motion settles.
  5. Capture distant content only when it approaches the viewport.

  The unavoidable first compositor round trip is therefore hidden behind an existing
  picture instead of blocking input or showing grey.

  ### 4. Fix zoom-target resolution

  The normal thumbnail ceiling remains 2× at OmariOverview.qml:3424, which can undersample
  a thumbnail when it is magnified back to window size.

  Introduce one explicit zoom-texture target:

  - Select it before opened becomes true.
  - Change it to the clicked window before a dive begins.
  - Give only that thumbnail a ceiling sufficient for 1 / geomScale, capped by the source
    resolution.

  - Demote it after the transition while the overview is idle.

  Do not derive this solely from diveRow and diveApp; those are not assigned during
  opening. Verify that promotion does not introduce a texture-allocation hitch on 4K or
  integrated-GPU systems.

  ### 5. Keep the dive snapshot-based initially

  Default to one frozen snapshot throughout the dive. During the existing pre-ramp dispatch
  wait, A/B test:

  1. No refresh.
  2. One fresh captureFrame() for the target.
  3. One live target during the dive.

  Option 3 should ship only if the visual landing is materially better and timing shows no
  regression. It reintroduces the expensive capture/layer loop during the most sensitive
  animation.

  ### 6. Profile secondary costs afterward

  The per-row wallpaper shadow at OmariOverview.qml:3104 is not yet proven to be a
  recurring animation cost: its layer is static, and monitor widths/crops may differ.
  Reprofile after snapshot mode. If significant, replace the blur with a cheaper static
  shadow or cache it per monitor geometry.

  ### 7. Clean up stale documentation

  Update:

  - The motion-freezing claim at README.md:338.
  - The unused screencopy claim at KineticScroll.qml:138.
  - README and panel wording that promises “live window thumbnails.”
  - Live-specific comments around the capture binding and margins.

  ## Acceptance criteria

  - Zero free-running thumbnail streams.
  - No synchronized recapture burst when motion settles.
  - Existing snapshots appear immediately; no grey flash on normal reopen.
  - Gestures remain proportional, reversible, and responsive from their first event.
  - On the slower reference machine, warm-motion p95 stays within one display interval,
    with no repeated two-frame hitches.

  - Opening and dive endpoints remain within one device pixel of the real window.
  - Zoom-target text remains sharp across same-monitor, mixed-DPI, fractional-scale, and
    reserved-bar configurations.

  - Transparent windows remain transparent.
  - At most one full-resolution zoom layer is retained.
  - Failed or remapped captures recover without becoming permanent retry loops.

  No files were changed; this plan is based on the current uncommitted working tree.