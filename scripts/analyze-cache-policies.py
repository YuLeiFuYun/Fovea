#!/usr/bin/env python3
"""用精确离线最优解和多类 trace 比较缓存策略。"""

from __future__ import annotations

from collections import OrderedDict, deque
from dataclasses import dataclass
from datetime import datetime, timezone
import argparse
import hashlib
import itertools
import json
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / ".artifacts/mathematics/cache-policies.json"
WORKBENCH_CATALOG = (
    ROOT
    / "Examples/FoveaWorkbenchApp/FoveaWorkbench/Resources/workbench-media-catalog.json"
)
WORKBENCH_LOCAL_MEDIA = (
    ROOT / "Examples/FoveaWorkbenchApp/FoveaWorkbench/Resources/LocalMedia"
)


@dataclass(frozen=True)
class Request:
    key: str
    size: int
    miss_cost: int


@dataclass(frozen=True)
class Trace:
    name: str
    capacity: int
    requests: tuple[Request, ...]
    description: str


@dataclass
class Result:
    requests: int = 0
    hits: int = 0
    hit_bytes: int = 0
    saved_cost: int = 0
    metadata_updates: int = 0

    def record(self, request: Request, hit: bool, metadata_updates: int = 0) -> None:
        self.requests += 1
        self.metadata_updates += metadata_updates
        if hit:
            self.hits += 1
            self.hit_bytes += request.size
            self.saved_cost += request.miss_cost


class Policy:
    name = "abstract"
    model_boundary = "未声明"

    def __init__(self, capacity: int) -> None:
        self.capacity = capacity
        self.result = Result()

    def access(self, request: Request) -> None:
        raise NotImplementedError


class LRU(Policy):
    name = "lru"
    model_boundary = "精确字节容量 LRU；命中移动到 MRU。"

    def __init__(self, capacity: int) -> None:
        super().__init__(capacity)
        self.items: OrderedDict[str, Request] = OrderedDict()
        self.used = 0

    def access(self, request: Request) -> None:
        if request.key in self.items:
            self.items.move_to_end(request.key)
            self.result.record(request, True, 1)
            return
        self.result.record(request, False)
        if request.size > self.capacity:
            return
        while self.used + request.size > self.capacity:
            _, victim = self.items.popitem(last=False)
            self.used -= victim.size
        self.items[request.key] = request
        self.used += request.size


class Sieve(Policy):
    name = "sieve"
    model_boundary = "字节容量 SIEVE；命中只设置 visited，淘汰时给予一次 second chance。"

    @dataclass
    class Entry:
        request: Request
        visited: bool = False

    def __init__(self, capacity: int) -> None:
        super().__init__(capacity)
        self.entries: list[Sieve.Entry] = []
        self.index: dict[str, Sieve.Entry] = {}
        self.used = 0
        self.hand = 0

    def access(self, request: Request) -> None:
        entry = self.index.get(request.key)
        if entry is not None:
            entry.visited = True
            self.result.record(request, True, 1)
            return
        self.result.record(request, False)
        if request.size > self.capacity:
            return
        while self.used + request.size > self.capacity:
            self.evict_one()
        entry = Sieve.Entry(request=request)
        self.entries.append(entry)
        self.index[request.key] = entry
        self.used += request.size
        if len(self.entries) == 1:
            self.hand = 0

    def evict_one(self) -> None:
        if not self.entries:
            raise RuntimeError("SIEVE 在空缓存上执行淘汰")
        inspected = 0
        while True:
            self.hand %= len(self.entries)
            entry = self.entries[self.hand]
            inspected += 1
            if entry.visited:
                entry.visited = False
                self.hand = (self.hand - 1) % len(self.entries)
                self.result.metadata_updates += 1
                continue
            self.used -= entry.request.size
            self.index.pop(entry.request.key)
            self.entries.pop(self.hand)
            if self.entries:
                self.hand = (self.hand - 1) % len(self.entries)
            else:
                self.hand = 0
            self.result.metadata_updates += inspected
            return


class GDSF(Policy):
    name = "gdsf"
    model_boundary = "以 frequency × missCost / size 形成 GreedyDual-Size-Frequency 优先级。"

    @dataclass
    class Entry:
        request: Request
        frequency: int
        priority: float

    def __init__(self, capacity: int) -> None:
        super().__init__(capacity)
        self.items: dict[str, GDSF.Entry] = {}
        self.used = 0
        self.inflation = 0.0

    @staticmethod
    def density(request: Request, frequency: int) -> float:
        return frequency * request.miss_cost / request.size

    def access(self, request: Request) -> None:
        entry = self.items.get(request.key)
        if entry is not None:
            entry.frequency += 1
            entry.priority = self.inflation + self.density(request, entry.frequency)
            self.result.record(request, True, 1)
            return
        self.result.record(request, False)
        if request.size > self.capacity:
            return
        while self.used + request.size > self.capacity:
            victim_key, victim = min(
                self.items.items(),
                key=lambda item: (item[1].priority, item[0]),
            )
            self.inflation = victim.priority
            self.used -= victim.request.size
            self.items.pop(victim_key)
            self.result.metadata_updates += 1
        priority = self.inflation + self.density(request, 1)
        self.items[request.key] = GDSF.Entry(request, 1, priority)
        self.used += request.size


class FrequencyDensityLRU(Policy):
    """以近期频率/字节成本决定准入，淘汰顺序仍保持 LRU。"""

    name = "frequency-density-lru"
    model_boundary = "项目研究启发式；固定窗口精确计数，不代表论文级 TinyLFU。"

    def __init__(self, capacity: int, sample_size: int = 64) -> None:
        super().__init__(capacity)
        self.items: OrderedDict[str, Request] = OrderedDict()
        self.used = 0
        self.sample_size = max(8, sample_size)
        self.window: deque[str] = deque()
        self.frequency: dict[str, int] = {}

    def observe(self, key: str) -> None:
        self.window.append(key)
        self.frequency[key] = self.frequency.get(key, 0) + 1
        if len(self.window) > self.sample_size:
            expired = self.window.popleft()
            remaining = self.frequency[expired] - 1
            if remaining == 0:
                self.frequency.pop(expired)
            else:
                self.frequency[expired] = remaining
        self.result.metadata_updates += 1

    def access(self, request: Request) -> None:
        self.observe(request.key)
        if request.key in self.items:
            self.items.move_to_end(request.key)
            self.result.record(request, True, 1)
            return
        self.result.record(request, False)
        if request.size > self.capacity:
            return
        if self.used + request.size <= self.capacity:
            self.items[request.key] = request
            self.used += request.size
            return
        victims: list[tuple[str, Request]] = []
        reclaimed = 0
        for key, victim in self.items.items():
            victims.append((key, victim))
            reclaimed += victim.size
            if self.used - reclaimed + request.size <= self.capacity:
                break
        if victims:
            candidate_frequency = self.frequency.get(request.key, 0)
            candidate_value = candidate_frequency * request.miss_cost
            # 交叉相乘比较价值密度，避免浮点误差。
            for key, victim in victims:
                victim_frequency = self.frequency.get(key, 0)
                victim_value = victim_frequency * victim.miss_cost
                if candidate_value * victim.size < victim_value * request.size:
                    return
        for key, victim in victims:
            self.items.pop(key)
            self.used -= victim.size
        self.items[request.key] = request
        self.used += request.size


class S3FIFOByteAdapted(Policy):
    """S3-FIFO 的确定性字节容量研究适配，不冒充原论文的全部实现细节。"""

    name = "s3-fifo-byte-adapted"
    model_boundary = (
        "三队列 quick-demotion 结构；S/M 按字节容量，ghost 按键数量有界。"
        "用于图片尺寸不等的反例搜索，不是逐行复刻某个生产实现。"
    )

    @dataclass
    class Entry:
        request: Request
        frequency: int = 0

    def __init__(self, capacity: int) -> None:
        super().__init__(capacity)
        self.small_target = max(1, capacity // 10)
        self.small: OrderedDict[str, S3FIFOByteAdapted.Entry] = OrderedDict()
        self.main: OrderedDict[str, S3FIFOByteAdapted.Entry] = OrderedDict()
        self.ghost: OrderedDict[str, None] = OrderedDict()
        self.small_used = 0
        self.main_used = 0
        self.ghost_limit = max(1, capacity)

    @property
    def used(self) -> int:
        return self.small_used + self.main_used

    def access(self, request: Request) -> None:
        entry = self.small.get(request.key)
        if entry is None:
            entry = self.main.get(request.key)
        if entry is not None:
            entry.frequency = min(3, entry.frequency + 1)
            self.result.record(request, True, 1)
            return

        self.result.record(request, False)
        if request.size > self.capacity:
            return
        if request.key in self.ghost:
            self.ghost.pop(request.key)
            self.main[request.key] = self.Entry(request=request)
            self.main_used += request.size
        else:
            self.small[request.key] = self.Entry(request=request)
            self.small_used += request.size
        self.trim()

    def trim(self) -> None:
        while self.used > self.capacity:
            if self.small and (self.small_used > self.small_target or not self.main):
                self.evict_small()
            else:
                self.evict_main()
        self.audit()

    def evict_small(self) -> None:
        key, entry = self.small.popitem(last=False)
        self.small_used -= entry.request.size
        self.result.metadata_updates += 1
        if entry.frequency > 1:
            entry.frequency = 0
            self.main[key] = entry
            self.main_used += entry.request.size
            return
        self.ghost[key] = None
        self.ghost.move_to_end(key)
        while len(self.ghost) > self.ghost_limit:
            self.ghost.popitem(last=False)
            self.result.metadata_updates += 1

    def evict_main(self) -> None:
        if not self.main:
            if self.small:
                self.evict_small()
                return
            raise RuntimeError("S3-FIFO 在空缓存上执行淘汰")
        while True:
            key, entry = self.main.popitem(last=False)
            self.result.metadata_updates += 1
            if entry.frequency > 0:
                entry.frequency -= 1
                self.main[key] = entry
                continue
            self.main_used -= entry.request.size
            return

    def audit(self) -> None:
        if set(self.small) & set(self.main):
            raise RuntimeError("S3-FIFO 同一 key 同时位于 small 和 main")
        if self.used > self.capacity:
            raise RuntimeError("S3-FIFO 超过字节容量")
        if self.small_used != sum(entry.request.size for entry in self.small.values()):
            raise RuntimeError("S3-FIFO small 记账漂移")
        if self.main_used != sum(entry.request.size for entry in self.main.values()):
            raise RuntimeError("S3-FIFO main 记账漂移")


class FrequencySketch:
    """确定性的四行、四位饱和 Count-Min sketch，并按样本窗口衰减。"""

    def __init__(self, capacity: int) -> None:
        width = 16
        target = max(16, capacity * 8)
        while width < target:
            width *= 2
        self.width = width
        self.tables = [[0] * width for _ in range(4)]
        self.seeds = (b"fovea-0", b"fovea-1", b"fovea-2", b"fovea-3")
        self.sample_size = max(64, capacity * 10)
        self.samples = 0
        self.metadata_updates = 0

    def indices(self, key: str) -> tuple[int, int, int, int]:
        encoded = key.encode("utf-8")
        return tuple(
            int.from_bytes(hashlib.blake2b(encoded, key=seed, digest_size=8).digest(), "little")
            & (self.width - 1)
            for seed in self.seeds
        )  # type: ignore[return-value]

    def estimate(self, key: str) -> int:
        return min(table[index] for table, index in zip(self.tables, self.indices(key), strict=True))

    def increment(self, key: str) -> None:
        indices = self.indices(key)
        estimate = min(table[index] for table, index in zip(self.tables, indices, strict=True))
        for table, index in zip(self.tables, indices, strict=True):
            if table[index] == estimate and table[index] < 15:
                table[index] += 1
                self.metadata_updates += 1
        self.samples += 1
        if self.samples >= self.sample_size:
            for table in self.tables:
                for index, value in enumerate(table):
                    table[index] = value >> 1
            self.metadata_updates += len(self.tables) * self.width
            self.samples = 0


class CostSizeAwareWindowTinyLFU(Policy):
    """面向图片对象的 W-TinyLFU 研究候选：窗口吸收突发，主区按价值密度准入。"""

    name = "cost-size-aware-wtinylfu"
    model_boundary = (
        "使用有界 Count-Min sketch、字节容量 window/main 和 frequency × missCost / size 准入；"
        "这是 Fovea 候选组合，不声称等同于 Caffeine 或 size-aware TinyLFU 论文实现。"
    )

    def __init__(self, capacity: int) -> None:
        super().__init__(capacity)
        self.window_target = max(1, capacity // 100)
        self.main_capacity = max(0, capacity - self.window_target)
        self.window: OrderedDict[str, Request] = OrderedDict()
        self.main: OrderedDict[str, Request] = OrderedDict()
        self.window_used = 0
        self.main_used = 0
        self.sketch = FrequencySketch(capacity)

    @property
    def used(self) -> int:
        return self.window_used + self.main_used

    def access(self, request: Request) -> None:
        self.sketch.increment(request.key)
        if request.key in self.window:
            self.window.move_to_end(request.key)
            self.result.record(request, True, self.take_sketch_updates())
            return
        if request.key in self.main:
            self.main.move_to_end(request.key)
            self.result.record(request, True, self.take_sketch_updates())
            return

        self.result.record(request, False, self.take_sketch_updates())
        if request.size > self.capacity:
            return
        self.window[request.key] = request
        self.window_used += request.size
        while self.window_used > self.window_target and self.window:
            _, candidate = self.window.popitem(last=False)
            self.window_used -= candidate.size
            self.admit_to_main(candidate)
        self.audit()

    def take_sketch_updates(self) -> int:
        updates = self.sketch.metadata_updates
        self.sketch.metadata_updates = 0
        return updates

    def density_numerator(self, request: Request) -> int:
        return max(1, self.sketch.estimate(request.key)) * request.miss_cost

    def admit_to_main(self, candidate: Request) -> None:
        if candidate.size > self.main_capacity:
            return
        if self.main_used + candidate.size <= self.main_capacity:
            self.main[candidate.key] = candidate
            self.main_used += candidate.size
            return

        victims: list[tuple[str, Request]] = []
        reclaimed = 0
        for key, victim in self.main.items():
            victims.append((key, victim))
            reclaimed += victim.size
            if self.main_used - reclaimed + candidate.size <= self.main_capacity:
                break
        if self.main_used - reclaimed + candidate.size > self.main_capacity:
            return

        candidate_value = self.density_numerator(candidate)
        for _, victim in victims:
            victim_value = self.density_numerator(victim)
            if candidate_value * victim.size < victim_value * candidate.size:
                return
        for key, victim in victims:
            self.main.pop(key)
            self.main_used -= victim.size
            self.result.metadata_updates += 1
        self.main[candidate.key] = candidate
        self.main_used += candidate.size

    def audit(self) -> None:
        if set(self.window) & set(self.main):
            raise RuntimeError("W-TinyLFU 同一 key 同时位于 window 和 main")
        if self.used > self.capacity:
            raise RuntimeError("W-TinyLFU 超过字节容量")
        if self.window_used != sum(item.size for item in self.window.values()):
            raise RuntimeError("W-TinyLFU window 记账漂移")
        if self.main_used != sum(item.size for item in self.main.values()):
            raise RuntimeError("W-TinyLFU main 记账漂移")


POLICIES = (
    LRU,
    Sieve,
    S3FIFOByteAdapted,
    GDSF,
    FrequencyDensityLRU,
    CostSizeAwareWindowTinyLFU,
)


def repeated(keys: Iterable[str], rounds: int, size: int = 1, cost: int = 5) -> list[Request]:
    return [Request(key, size, cost) for _ in range(rounds) for key in keys]


def workbench_bundled_trace() -> Trace:
    catalog = json.loads(WORKBENCH_CATALOG.read_text())
    bundled = [
        asset for asset in catalog["assets"]
        if asset["sourceKind"] == "bundled"
    ][:8]
    if len(bundled) < 8:
        raise ValueError("Workbench 至少需要八个随包真实素材生成缓存 trace")

    requests: dict[str, Request] = {}
    for asset in bundled:
        path = WORKBENCH_LOCAL_MEDIA / asset["bundledResourceName"]
        size_units = max(1, (path.stat().st_size + 65_535) // 65_536)
        pixel_units = max(1, (asset["originalPixelWidth"] * asset["originalPixelHeight"] + 999_999) // 1_000_000)
        requests[asset["id"]] = Request(
            asset["id"],
            size_units,
            size_units + 4 * pixel_units,
        )

    keys = [asset["id"] for asset in bundled]
    order = [
        keys[0], keys[1], keys[2], keys[3], keys[4], keys[5],
        keys[0], keys[1], keys[6], keys[7], keys[0], keys[2], keys[3],
        keys[0], keys[1], keys[2], keys[3],
    ]
    total_size = sum(request.size for request in requests.values())
    return Trace(
        "workbench-bundled-reentry",
        max(1, total_size * 3 // 5),
        tuple(requests[key] for key in order),
        "由 Workbench 随包真实图片字节和原始像素成本构造的浏览—离屏—回屏序列。",
    )


def traces() -> tuple[Trace, ...]:
    hot_scan: list[Request] = []
    for round_index in range(10):
        hot_scan.extend(repeated(["avatar-a", "avatar-b", "avatar-c", "avatar-d"], 1, 1, 4))
        hot_scan.append(Request(f"scan-{round_index}", 5, 6))

    phase_shift = repeated(["a", "b", "c", "d"], 8, 2, 5)
    phase_shift += repeated(["e", "f", "g", "h"], 8, 2, 5)

    mixed_cost: list[Request] = []
    for index in range(8):
        mixed_cost.extend(
            [
                Request("remote-hero", 5, 30),
                Request("local-icon-a", 1, 1),
                Request("local-icon-b", 1, 1),
                Request(f"cold-thumb-{index}", 2, 3),
                Request("remote-avatar", 1, 12),
            ]
        )

    cyclic = repeated([f"gallery-{index}" for index in range(9)], 8, 1, 4)

    zipf_sequence = (
        ["a"] * 12
        + ["b"] * 8
        + ["c"] * 6
        + ["d"] * 4
        + ["e"] * 3
        + ["f", "g", "h", "i"]
    )
    zipf: list[Request] = []
    for shift in range(5):
        rotated = zipf_sequence[shift:] + zipf_sequence[:shift]
        zipf.extend(Request(key, 1 + (ord(key) - ord("a")) % 3, 3 + (10 - min(9, ord(key) - ord("a")))) for key in rotated)

    one_hit_wonders: list[Request] = []
    for index in range(8):
        one_hit_wonders.extend(
            [
                Request("hot-avatar-a", 1, 8),
                Request("hot-avatar-b", 1, 8),
                Request(f"one-hit-{index}", 2, 3),
            ]
        )

    size_cost_skew: list[Request] = []
    for index in range(8):
        size_cost_skew.extend(
            [
                Request("hot-small", 1, 12),
                Request("hot-medium", 3, 18),
                Request(f"cold-large-{index}", 7, 8),
                Request("expensive-hero", 8, 60),
            ]
        )

    return (
        Trace(
            "hot-small-with-large-scan",
            9,
            tuple(hot_scan),
            "小型热点图像与一次性大图扫描交错，检验扫描污染。",
        ),
        Trace(
            "phase-shift",
            8,
            tuple(phase_shift),
            "热点集合在运行中切换，检验策略适应非平稳分布的速度。",
        ),
        Trace(
            "mixed-source-cost",
            9,
            tuple(mixed_cost),
            "远程高代价图、本地低代价图与冷缩略图混合，目标是最大化避免的代价。",
        ),
        Trace(
            "cyclic-gallery",
            6,
            tuple(cyclic),
            "工作集略大于缓存的循环画廊，是 LRU 的典型对抗序列。",
        ),
        Trace(
            "zipf-mixed-size",
            10,
            tuple(zipf),
            "带尺寸差异的确定性 Zipf 近似分布。",
        ),
        Trace(
            "one-hit-wonder-burst",
            6,
            tuple(one_hit_wonders),
            "重复头像与一次性缩略图交错，检验 quick demotion 和准入过滤。",
        ),
        Trace(
            "size-cost-skew",
            12,
            tuple(size_cost_skew),
            "尺寸、下载代价和解码价值不一致，检验 size/cost-aware admission。",
        ),
        workbench_bundled_trace(),
    )


def all_feasible_subsets(objects: dict[str, Request], capacity: int) -> tuple[frozenset[str], ...]:
    keys = sorted(objects)
    result: list[frozenset[str]] = []
    for count in range(len(keys) + 1):
        for combination in itertools.combinations(keys, count):
            if sum(objects[key].size for key in combination) <= capacity:
                result.append(frozenset(combination))
    return tuple(result)


def exact_offline_saved_cost(trace: Trace) -> int:
    """对小型有限 trace 穷举可行缓存集合，得到字节容量下的精确离线最优值。"""
    objects: dict[str, Request] = {}
    for request in trace.requests:
        prior = objects.get(request.key)
        if prior is not None and (prior.size, prior.miss_cost) != (request.size, request.miss_cost):
            raise ValueError(f"对象属性在 trace 中变化：{request.key}")
        objects[request.key] = request
    subsets = all_feasible_subsets(objects, trace.capacity)
    states: dict[frozenset[str], int] = {frozenset(): 0}
    subset_of: dict[frozenset[str], tuple[frozenset[str], ...]] = {
        available: tuple(candidate for candidate in subsets if candidate <= available)
        for available in subsets
    }
    for request in trace.requests:
        next_states: dict[frozenset[str], int] = {}
        for cache, saved in states.items():
            hit = request.key in cache
            available = cache if hit else frozenset((*cache, request.key))
            gain = request.miss_cost if hit else 0
            for candidate in subset_of.get(available, (cache,)):
                value = saved + gain
                if value > next_states.get(candidate, -1):
                    next_states[candidate] = value
        states = next_states
    return max(states.values(), default=0)


def evaluate(trace: Trace, policy_type: type[Policy]) -> Result:
    policy = policy_type(trace.capacity)
    for request in trace.requests:
        policy.access(request)
    return policy.result


def validate_exact_oracle() -> None:
    tiny = Trace(
        "oracle-self-test",
        1,
        (Request("a", 1, 5), Request("b", 1, 7), Request("a", 1, 5)),
        "已知最优值自检",
    )
    if exact_offline_saved_cost(tiny) != 5:
        raise RuntimeError("精确离线 oracle 自检失败")


def main() -> int:
    validate_exact_oracle()
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    trace_reports: list[dict[str, object]] = []
    errors: list[str] = []
    best_counts = {policy.name: 0 for policy in POLICIES}
    for trace in traces():
        oracle = exact_offline_saved_cost(trace)
        policies: list[dict[str, object]] = []
        best_saved = -1
        for policy_type in POLICIES:
            result = evaluate(trace, policy_type)
            if result.saved_cost > oracle:
                errors.append(
                    f"{trace.name}/{policy_type.name} 超过精确离线最优值："
                    f"{result.saved_cost}>{oracle}"
                )
            best_saved = max(best_saved, result.saved_cost)
            policies.append(
                {
                    "name": policy_type.name,
                    "modelBoundary": policy_type.model_boundary,
                    "hits": result.hits,
                    "objectHitRatio": round(result.hits / max(1, result.requests), 6),
                    "byteHitRatio": round(
                        result.hit_bytes
                        / max(1, sum(request.size for request in trace.requests)),
                        6,
                    ),
                    "savedCost": result.saved_cost,
                    "oracleRegretRatio": round(
                        (oracle - result.saved_cost) / max(1, oracle),
                        6,
                    ),
                    "metadataUpdates": result.metadata_updates,
                }
            )
        for policy in policies:
            if policy["savedCost"] == best_saved:
                best_counts[str(policy["name"])] += 1
        trace_reports.append(
            {
                "name": trace.name,
                "description": trace.description,
                "capacityUnits": trace.capacity,
                "requestCount": len(trace.requests),
                "uniqueObjects": len({request.key for request in trace.requests}),
                "offlineOptimalSavedCost": oracle,
                "policies": policies,
            }
        )

    report = {
        "schemaVersion": 2,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "objective": (
            "主目标为避免的加载代价；同时报告对象命中率、字节命中率、"
            "相对精确离线最优值的 regret 与元数据更新次数。"
        ),
        "truthBoundary": (
            "离线最优只对内置有限 trace 和离散容量精确；S3-FIFO 与 W-TinyLFU 条目含明确的图片字节容量适配边界，结果用于寻找反例和筛选生产候选，不是未知生产流量的全局证明。"
        ),
        "bestTraceCounts": best_counts,
        "traces": trace_reports,
        "errors": errors,
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n")

    print("Cache policy analysis:")
    for trace in trace_reports:
        summary = ", ".join(
            f"{policy['name']}={policy['savedCost']}"
            for policy in trace["policies"]
        )
        print(
            f"  {trace['name']}: oracle={trace['offlineOptimalSavedCost']} {summary}"
        )
    print(f"Artifact: {output.relative_to(ROOT)}")
    for error in errors:
        print(f"error: {error}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
