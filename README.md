# NYC L Train Bottleneck Monitor
The question: Where do trains on the L line repeatedly run slower than usual, and when should a transit analyst flag a segment as a real proble
This project compares how quickly different alert policies detect persistent slowdowns and how often they flag short lived spikes. The initial data check covers the southbound L from Union Square to 3 Av.

Data source: [TransitLab analysis of MTA data](https://docs.transitlab.nyc/datasets/subway-segment-times/), [CC BY 4.0](https://docs.transitlab.nyc/start/license/).


https://docs.transitlab.nyc/

04_prepare_l_train_days.sql creates one row per weekday for each of the 44 directional L train stop pairs selected using 2025 data. December 2024 gives rolling baseline history, 2025 is used for development, and January–April 2026 is saved for evaluation. The view distinguishes missing records from unusable timings, so an unknown weekday can break an alert streak.
The source was already aggregated by segment and day. I built a weekday calendar for every monitored segment so missing dates were explicit. That way, two slow readings separated by a day with no data couldn’t accidentally trigger a consecutive day alert. ^^^^^^^^^^