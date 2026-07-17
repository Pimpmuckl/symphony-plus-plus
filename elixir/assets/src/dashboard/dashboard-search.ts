import type { WorkRequestPackage, WorkPackageCard, WorkRequestCard, WorkRequestDetail } from "@/types/dashboard";
import type { ProductTreeNode } from "@/types/product-tree";

import type { RepoSummary } from "./dashboard-data";

export type WorkstreamSearchResult = {
  active: boolean;
  repos: RepoSummary[];
  requestDetailsByRepo: Map<string, WorkRequestDetail[]>;
};

const MIN_FUZZY_TERM_LENGTH = 4;
const MIN_FUZZY_UNIQUE_CHARS = 3;
const VOWELS = /[aeiou]/;
const DIGITS = /\d/;

export function filterWorkstreamsBySearch(
  repos: RepoSummary[],
  requestDetailsByRepo: Map<string, WorkRequestDetail[]>,
  query: string,
): WorkstreamSearchResult {
  const terms = searchTerms(query);
  if (terms.length === 0) return { active: false, repos, requestDetailsByRepo };

  const filteredDetailsByRepo = new Map<string, WorkRequestDetail[]>();
  const filteredRepos = repos.flatMap((repo) => {
    const details = requestDetailsByRepo.get(repo.repoKey) ?? [];

    const repoMatches = matchesTerms(terms, repoFields(repo));
    const matchedPackageIds = new Set(repo.packages.filter((pkg) => matchesTerms(terms, packageFields(pkg))).map((pkg) => pkg.id));
    const matchedDetails = details.filter((detail) => matchesTerms(terms, requestDetailFields(detail)) || detailHasPackage(detail, matchedPackageIds));
    const visiblePackageIds = new Set(matchedDetails.flatMap((detail) => (detail.work_packages ?? []).map((slice) => slice.work_package_id).filter(Boolean)));
    const visibleRequestIds = new Set(matchedDetails.map((detail) => detail.work_request.id));
    const packages = repo.packages.filter((pkg) => matchedPackageIds.has(pkg.id) || visiblePackageIds.has(pkg.id));
    const requests = repo.requests.filter((request) => visibleRequestIds.has(request.id) || matchesTerms(terms, requestFields(request)));

    if (!repoMatches && matchedDetails.length + packages.length + requests.length === 0) return [];

    filteredDetailsByRepo.set(repo.repoKey, matchedDetails);
    return [{ ...repo, packages, requests }];
  });

  return { active: true, repos: filteredRepos, requestDetailsByRepo: filteredDetailsByRepo };
}

export function matchesDashboardSearch(query: string, fields: Array<string | null | undefined>) {
  const terms = searchTerms(query);
  return terms.length === 0 || matchesTerms(terms, fields);
}

function searchTerms(query: string) {
  return normalize(query).split(/\s+/).filter(Boolean);
}

function matchesTerms(terms: string[], fields: Array<string | null | undefined>) {
  const normalizedFields = fields.map(normalize).filter(Boolean);
  return terms.every((term) => normalizedFields.some((field) => field.includes(term) || (canFuzzyMatch(term) && fuzzyIncludes(field, term))));
}

function fuzzyIncludes(field: string, term: string) {
  let index = 0;
  for (const char of field) {
    if (char === term[index]) index += 1;
    if (index === term.length) return true;
  }
  return false;
}

function canFuzzyMatch(term: string) {
  return term.length >= MIN_FUZZY_TERM_LENGTH && new Set(term).size >= MIN_FUZZY_UNIQUE_CHARS && (!VOWELS.test(term) || DIGITS.test(term));
}

function normalize(value: string | null | undefined) {
  return (value ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function repoFields(repo: RepoSummary) {
  return [repo.repo, repo.repoKey, repo.repoRemote, ...repo.baseBranches];
}

function requestDetailFields(detail: WorkRequestDetail) {
  return [
    ...requestFields(detail.work_request),
    ...(detail.clarification_questions ?? []).map((question) => question.id),
    ...(detail.decision_logs ?? []).map((decision) => decision.id),
    ...(detail.product_tree?.nodes ?? []).flatMap(productNodeFields),
    ...(detail.work_packages ?? []).flatMap(sliceFields),
  ];
}

function requestFields(request: WorkRequestCard) {
  return [request.id, request.title, request.status, request.base_branch, request.work_type, request.desired_dispatch_shape];
}

function packageFields(pkg: WorkPackageCard) {
  return [pkg.id, pkg.title, pkg.status, pkg.kind, pkg.base_branch];
}

function sliceFields(slice: WorkRequestPackage) {
  return [slice.id, slice.title, slice.status, slice.work_package_id, slice.work_package_status, slice.kind, slice.base_branch];
}

function productNodeFields(node: ProductTreeNode) {
  return [node.id, node.title, node.node_kind, node.completion_label];
}

function detailHasPackage(detail: WorkRequestDetail, packageIds: Set<string>) {
  return (detail.work_packages ?? []).some((slice) => Boolean(slice.work_package_id && packageIds.has(slice.work_package_id)));
}
