# Changelog

## 1.3.0
- Changed the command prefix from `/sealclubplus` to `/scp`.
- Added per-seal kill statistics next to each timer, including kills for the current or most recent seal cycle and average kills per seal.
- Changed seal-cycle kill tracking so the most recent drop count remains visible until that seal becomes eligible again.
- Reset live kill counters to zero on zone transition because zoning resets seal eligibility.
- Shortened the ready-state labels to `BS Ready` and `KS Ready`.

## 1.2.1
- Hid the main SealClubPlus timer window while the player is not logged in, in a cutscene or event, or transitioning zones.
- Kept the SealClubPlus config window available during those hidden states so settings can still be adjusted.

## 1.2.0
- Added configurable kill detection methods for chat defeat text, kill-message packet detection, and reward packet detection.
- Added kill deduplication so multiple enabled detection methods do not double count the same kill.
- Added pet-aware kill detection via packet-based actor checks so pet killing blows can count.
- Added a sound preview button in the config window to test the selected `.wav` immediately.
- Added a shared Beastman timer option that forces both timers to use the Beastman cooldown and synchronize on either seal drop.

## 1.1.0
- Created SealClubPlus as a separate clone/fork of the original SealClub addon.
- Renamed the addon identity, command, window ids, and callback ids so it can coexist with the original addon.
- Added ready-sound support with bundled `water_tink.wav` audio.
- Added a sound dropdown in the config window for selecting `.wav` files from the addon sounds folder.
- Added README notes for upstream attribution and licensing.