New Read ME Start use stuff from below
# NYC L Train Bottleneck Monitor

The Question: Where do L trains repeatedly run slower than usual, and when should a transit analyst investigate?

To answer this question I built a PostgreSQL and Python workflow to identify sustained slowdowns, compare alert policies, and present the results in two interactive Tableau dashboards. The goal is to help an operations team prioritize investigations while understanding the consequences/tradeoffs of fewer alerts.

## Main result

In the January–April 2026 evaluation, requiring two consecutive slow weekdays reduced alerts by **78%**, from **235 to 52**, while detecting **13 of 14 reference slowdown episodes**.

Among episodes detected by both policies, the additional delay had a median of **one weekday** and a maximum of **four weekdays**.

These results support an operational choice between investigation workload and detection speed.

## Data and evaluation design

The source contains daily travel times between station pairs, measured separately in each direction(North/South). Travel time includes the stop at the second station.

I imported **1.67 million subway records across 67 months** from TransitLab’s analysis of MTA data. From this dataset, I selected **44 directional L train station pairs** with at least 95% usable weekday data during 2025.

The analysis uses three periods.

| Period | Purpose |
|---|---|
| September–December 2024 | Supplies historical observations for the first rolling baselines |
| January–December 2025 | Develops and compares candidate alert rules |
| January–April 2026 | Evaluates the same candidate rules on later data reserved from development |

The evaluation covers **86 weekdays and 3,784 segment observations**. Segment selection uses 2025 coverage, so evaluation data does not determine which segments qualify.

Source and license are available through [TransitLab](https://docs.transitlab.nyc/datasets/subway-segment-times/) and [CC BY 4.0](https://docs.transitlab.nyc/start/license/).
#


# NYC L Train Bottleneck Monitor
The question: Where do trains on the L line repeatedly run slower than usual, and when should a transit analyst flag a segment as a real proble
This project compares how quickly different alert policies detect persistent slowdowns and how often they flag short lived spikes. The initial data check covers the southbound L from Union Square to 3 Av.

Data source: [TransitLab analysis of MTA data](https://docs.transitlab.nyc/datasets/subway-segment-times/), [CC BY 4.0](https://docs.transitlab.nyc/start/license/).


https://docs.transitlab.nyc/

04_prepare_l_train_days.sql creates one row per weekday for each of the 44 directional L train stop pairs selected using 2025 data. December 2024 gives rolling baseline history, 2025 is used for development, and January–April 2026 is saved for evaluation. The view distinguishes missing records from unusable timings, so an unknown weekday can break an alert streak.
The source was already aggregated by segment and day. I built a weekday calendar for every monitored segment so missing dates were explicit. That way, two slow readings separated by a day with no data couldn’t accidentally trigger a consecutive day alert. ^^^^^^^^^^

The initial AI reccomendation used a 10 weekday baseline. I questioned whether an unusually fast or slow two week period could distort that baseline and recommended testing longer windows. This led to comparing 10-, 20-, and 60-weekday baselines on development data and extending the warm up period to support them.
- from that original change is alot to debate whether its better to have a more reactive thing that fluctates or one that has a sustained baseline average which keeps the threshold relatively consistent.

Alert boundary = baseline + threshold
Threshold = whichever is larger: 10 seconds or 3 scaled MADs
Comparing 10-, 20-, and 60-weekday windows showed that the amount of historical data can change both the baseline and variability threshold. In one June example, the 10 day alert boundary rose enough to stop flagging elevated travel times while the 60 day candidate continued flagging them. We investigated the trade offs between adapting quickly to recent conditions and retaining longer historical context.

The variability threshold is the extra time above the baseline we require before calling a day slow. It gets larger when the previous travel times are more spread out. (We calculate using MAD x 3 or just 10 seconds)