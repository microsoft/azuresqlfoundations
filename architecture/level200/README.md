# Inside Azure SQL Hyperscale - Level 200

A five-section introduction to separate compute and storage, memory and SSD
caching, HA and zone redundancy, serverless and elastic pools, independently
sized named read replicas, and **Start here. Stay here.**

## Choose a format

| Asset | How to use it |
| --- | --- |
| [Interactive HTML](hyperscale-architecture-level200.html) | Download and open locally in Microsoft Edge. Use the five bottom buttons or arrow keys to select a section; Play tour advances automatically. No server, database, or network is required for playback. |
| [4K MP4](hyperscale-architecture-level200.mp4) | Silent, approximately 101-second tour at 3840 x 2160, 24 fps. |
| [Animated GIF](hyperscale-architecture-level200.gif) | Silent, looping tour at 1280 x 720, 10 fps. |
| [PowerPoint presentation](hyperscale-sections-level200.pptx) | Editable five-slide deck with embedded section videos. Copy slides into another deck as needed. |
| [PowerPoint Show](hyperscale-sections-level200.ppsx) | Open in desktop PowerPoint for full-screen playback. Videos start on slide entry; advance slides normally. |

GitHub displays HTML source rather than running the player. Download the HTML
file, or clone this repository, before opening it. The optional Original diagram
link uses the [companion SVG](../ch03-figure-01-architecture.svg); keep it at its
relative location when copying the player. Microsoft Learn source links require
internet access.

All formats share five colored footer labels. HTML buttons navigate; MP4, GIF,
and PowerPoint footers are visual indicators, not clickable navigation. The
current section is highlighted in the first four views. On the closing summary,
no footer item is highlighted; a spotlight cycles through the five middle
benefit cards. Reduced motion leaves the HTML summary cards static. PowerPoint
loops its ten-second summary video until you leave the slide; other section
videos play once. Videos are embedded, so no companion media files are needed.

## Scope and caveats

These are conceptual illustrations, not benchmark results, provisioning-time
guarantees, or zero-downtime promises. Compute changes and failover can interrupt
connections; applications retry. HA assumes zone redundancy was configured at
creation. Serverless auto-pause/resume is labeled Preview, requires an eligible
configuration and idle delay, and does not stop storage billing. Elastic pools
are provisioned, not serverless. Named replicas are read-only and can lag.
Technical notes and Microsoft Learn sources are included in the HTML player.

## Source

Published from [rgward/bwsql, architecture/level200](https://github.com/rgward/bwsql/tree/bw/hyperscale/architecture/level200),
commit `e26ed8e6dd199efc3db55d1004cd711aee3f1af7` (November 13, 2026).
The five finished assets are byte-for-byte copies. Export and verification
scripts remain in the source repository; these published assets do not require
those build dependencies.
