import type { WirePath } from "./router";

export function wireMorphs(previous: WirePath[], current: WirePath[]) {
  // ponytail: O(n²) over tiny visible wire sets; index by intent only if graphs grow large.
  const morphs = previous.flatMap((from) => {
    const to = bestMatch(from, current);
    return to ? [{ from, to }] : [];
  });
  const targeted = new Set(morphs.map((morph) => morph.to.key));
  for (const to of current) {
    if (targeted.has(to.key)) continue;
    const from = bestMatch(to, previous);
    if (from) morphs.push({ from, to });
  }
  return morphs;
}

function bestMatch(source: WirePath, candidates: WirePath[]) {
  let best: WirePath | undefined;
  let bestScore = 0;
  for (const candidate of candidates) {
    const shared = source.intentIds.filter((id) => candidate.intentIds.includes(id)).length;
    if (!shared) continue;
    const score = shared * 10
      + Number(shared === source.intentIds.length && shared === candidate.intentIds.length) * 2
      + Number(Boolean(source.bundle) === Boolean(candidate.bundle));
    if (score > bestScore) [best, bestScore] = [candidate, score];
  }
  return best;
}
