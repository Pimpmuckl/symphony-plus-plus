import { AnimatedBadge, AnimatedCardBody } from "@/components/dashboard/motion";
import { Badge } from "@/components/ui/badge";
import { BoardLaneColumn } from "@/components/dashboard/board-lanes";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { CardSignal } from "@/components/dashboard/card-signal";
import { GitBranch } from "lucide-react";
import { Separator } from "@/components/ui/separator";
import type { SignalTone, StateCardTone } from "@/components/dashboard/state-card-style";
import type { SoloSession } from "@/types/dashboard";
import { StateCard } from "@/components/dashboard/state-card";
import type { UpdateMotion } from "@/components/dashboard/motion";
import { formatStatus } from "@/lib/status-labels";
import { sortedCopy } from "@/lib/collections";
import { updateMotionAttributes } from "@/components/dashboard/motion-utils";
import { CardDetailSelect, DashboardUpdateAnimations } from "./runtime";
import { stripMarkdown } from "./dashboard-text";
import { EmptyPanel } from "./empty-panel";
import { detailDate } from "./detail-utils";
import { RepoSummaryPlate } from "./dashboard-settings";
import { interactiveCardProps, stateCardBodyMotionKey } from "./card-helpers";
import { repoDisplayName, repoIdentityKey, repoRemoteName } from "./dashboard-persistence";
import { soloSessionAttention, soloSessionLane, soloSessionStatusVariant, soloSessionUpdateKey } from "./solo-session-utils";

export function SoloSessions({
  loading,
  sessions,
  onSelectCard,
  updateAnimations,
}: {
  loading: boolean;
  sessions: SoloSession[];
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  if (loading) return <EmptyPanel title="Loading Solo Sessions" />;
  if (sessions.length === 0) {
    return <EmptyPanel title="No solo sessions" />;
  }

  return (
    <div className="grid gap-5">
      {soloSessionGroups(sessions).map((group) => (
        <SoloSessionGroup key={`${group.repoKey}:${group.baseBranch}`} group={group} onSelectCard={onSelectCard} updateAnimations={updateAnimations} />
      ))}
    </div>
  );
}

function SoloSessionGroup({
  group,
  onSelectCard,
  updateAnimations,
}: {
  group: {
    repoKey: string;
    repo: string;
    repoRemote?: string | null;
    baseBranch: string;
    active: SoloSession[];
    finished: SoloSession[];
    guidanceCount: number;
    blockerCount: number;
  };
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  return (
    <Card className="dashboard-glass-surface motion-card overflow-hidden">
      <CardHeader className="dashboard-panel-header border-b">
        <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <div className="min-w-0">
            <CardTitle className="flex items-center gap-2">
              <GitBranch className="size-4 text-primary" />
              <span className="truncate" title={group.repoRemote || undefined}>{group.repo}</span>
            </CardTitle>
            <p className="mt-1 truncate text-sm text-muted-foreground">{group.baseBranch}</p>
          </div>
          <div className="flex min-w-0 flex-wrap items-center gap-1.5 md:justify-end">
            <RepoSummaryPlate label="Active" value={group.active.length} tone="active" />
            <RepoSummaryPlate label="Finished" value={group.finished.length} tone="finished" />
            {group.guidanceCount > 0 ? <RepoSummaryPlate label="Guidance Needed" value={group.guidanceCount} tone="guidance" /> : null}
            {group.blockerCount > 0 ? <RepoSummaryPlate label="Active Blockers" value={group.blockerCount} tone="blocker" /> : null}
          </div>
        </div>
      </CardHeader>
      <CardContent className="p-3 sm:p-4">
        <div className="solo-board-shell">
          <div className="jira-board jira-board-solo">
            <SoloSessionLane
              title="Active"
              sessions={group.active}
              emptyLabel="No active solo sessions"
              onSelectCard={onSelectCard}
              updateAnimations={updateAnimations}
            />
            <SoloSessionLane
              title="Finished"
              sessions={group.finished}
              emptyLabel="No finished solo sessions"
              onSelectCard={onSelectCard}
              updateAnimations={updateAnimations}
            />
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

function SoloSessionLane({
  title,
  sessions,
  emptyLabel,
  onSelectCard,
  updateAnimations,
}: {
  title: string;
  sessions: SoloSession[];
  emptyLabel: string;
  onSelectCard: CardDetailSelect;
  updateAnimations: DashboardUpdateAnimations;
}) {
  return (
    <BoardLaneColumn title={title} count={sessions.length} emptyLabel={emptyLabel}>
      {sessions.map((session, index) => (
        <SoloSessionCard
          key={session.id}
          session={session}
          index={index}
          onSelectCard={() => onSelectCard({ kind: "solo", session })}
          motion={updateAnimations.motionFor(soloSessionUpdateKey(session))}
        />
      ))}
    </BoardLaneColumn>
  );
}

function SoloSessionCard({
  session,
  index,
  onSelectCard,
  motion,
}: {
  session: SoloSession;
  index: number;
  onSelectCard: () => void;
  motion?: UpdateMotion;
}) {
  const attention = soloSessionAttention(session);
  const latest = session.latest_entry;
  const latestText = latest?.title || stripMarkdown(latest?.body);
  const latestSignalValue = latest?.status ? formatStatus(latest.status) : latestText;
  const tone = soloSessionCardTone(session);
  const showLatest = latest && latestText && !soloSessionLatestIsRedundant(session, latestText);
  const bodyMotionKey = stateCardBodyMotionKey(
    "solo",
    session.id,
    attention.guidanceCount,
    attention.blockerCount,
    latestSignalValue,
    showLatest,
    latest?.kind_label,
    latest?.kind,
    latestText,
    session.last_activity_at,
    session.updated_at,
  );

  return (
    <StateCard
      tone={tone}
      className="stagger-item card-detail-trigger p-3"
      style={{ animationDelay: `${index * 35}ms` }}
      data-card-detail-kind="solo"
      {...updateMotionAttributes(motion)}
      {...interactiveCardProps(onSelectCard)}
    >
      <div className="flex min-w-0 items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold">{session.title || session.id}</p>
          <p className="mt-1 truncate text-xs text-muted-foreground">{session.caller_id || "Solo session"}</p>
        </div>
        <AnimatedBadge active={soloSessionStatusIsRunning(session.status)} label={formatStatus(session.status)} variant={soloSessionStatusVariant(session.status)} className="shrink-0" />
      </div>

      <AnimatedCardBody motionKey={bodyMotionKey}>
        {attention.guidanceCount > 0 || attention.blockerCount > 0 ? (
          <div className="mt-3 flex flex-wrap gap-1.5">
            {attention.guidanceCount > 0 ? <RepoSummaryPlate label="Guidance Needed" value={attention.guidanceCount} tone="guidance" /> : null}
            {attention.blockerCount > 0 ? <RepoSummaryPlate label="Active Blockers" value={attention.blockerCount} tone="blocker" /> : null}
          </div>
        ) : latestSignalValue ? (
          <CardSignal className="mt-3" label={soloSessionLatestSignalLabel(session)} value={latestSignalValue} tone={soloSessionLatestSignalTone(session)} />
        ) : null}

        {showLatest ? (
          <>
            <Separator className="my-3" />
            <div className="flex min-w-0 items-start gap-2">
              <Badge variant="secondary" className="shrink-0">
                {latest.kind_label || formatStatus(latest.kind)}
              </Badge>
              <p className="line-clamp-2 min-w-0 text-sm text-muted-foreground">{latestText}</p>
            </div>
          </>
        ) : null}

        <p className="mt-3 text-xs text-muted-foreground">Updated {detailDate(session.last_activity_at || session.updated_at || session.inserted_at)}</p>
      </AnimatedCardBody>
    </StateCard>
  );
}

function soloSessionStatusIsRunning(status?: string | null) {
  return ["active", "in_progress", "running"].includes(status || "");
}

function soloSessionGroups(sessions: SoloSession[]) {
  const groups = new Map<
    string,
    {
      repoKey: string;
      repo: string;
      repoRemote?: string | null;
      baseBranch: string;
      active: SoloSession[];
      finished: SoloSession[];
      guidanceCount: number;
      blockerCount: number;
    }
  >();

  sessions.forEach((session) => {
    const repoKey = repoIdentityKey(session);
    const repo = repoDisplayName(session);
    const baseBranch = session.base_branch?.trim() || "main";
    const key = `${repoKey}:${baseBranch}`;
    const group =
      groups.get(key) ||
      ({
        repoKey,
        repo,
        repoRemote: repoRemoteName(session),
        baseBranch,
        active: [],
        finished: [],
        guidanceCount: 0,
        blockerCount: 0,
      } satisfies {
        repo: string;
        repoKey: string;
        repoRemote?: string | null;
        baseBranch: string;
        active: SoloSession[];
        finished: SoloSession[];
        guidanceCount: number;
        blockerCount: number;
      });

    const attention = soloSessionAttention(session);
    group.repoRemote ||= repoRemoteName(session);
    group.guidanceCount += attention.guidanceCount;
    group.blockerCount += attention.blockerCount;

    if (soloSessionLane(session) === "finished") {
      group.finished.push(session);
    } else {
      group.active.push(session);
    }

    groups.set(key, group);
  });

  return [...groups.values()].map((group) => ({
    ...group,
    active: sortSoloSessions(group.active),
    finished: sortSoloSessions(group.finished),
  }));
}

function sortSoloSessions(sessions: SoloSession[]) {
  return sortedCopy(sessions, (left, right) => soloSessionTime(right) - soloSessionTime(left));
}

function soloSessionTime(session: SoloSession) {
  const value = session.last_activity_at || session.updated_at || session.inserted_at;
  const timestamp = value ? Date.parse(value) : 0;
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function soloSessionCardTone(session: SoloSession): StateCardTone {
  const attention = soloSessionAttention(session);
  const status = session.status || "";
  const latestText = [session.latest_entry?.kind, session.latest_entry?.kind_label, session.latest_entry?.status, session.latest_entry?.title, session.latest_entry?.body]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();

  if (attention.blockerCount > 0 || status === "blocked") return "blocked";
  if (attention.guidanceCount > 0 || status === "human_info_needed") return "guidance";
  if (["completed", "archived", "finished", "closed"].includes(status)) return "finished";
  if (latestText.includes("review")) return "review";
  if (latestText.includes("validation")) return latestText.includes("completed") ? "finished" : "implementing";
  if (status === "paused") return "merge";
  return "implementing";
}

function soloSessionLatestSignalLabel(session: SoloSession) {
  const latest = session.latest_entry;
  if (!latest) return "Latest";

  const latestText = [latest.kind, latest.kind_label, latest.status].filter(Boolean).join(" ").toLowerCase();
  if (latestText.includes("review")) return "Review";
  if (latestText.includes("validation")) return "Validation";
  if (latestText.includes("blocker") || latestText.includes("blocked")) return "Blocker";
  if (latestText.includes("guidance") || latestText.includes("human info")) return "Guidance";
  return latest.kind_label || "Latest";
}

function soloSessionLatestSignalTone(session: SoloSession): SignalTone {
  const latest = session.latest_entry;
  const text = [latest?.kind, latest?.kind_label, latest?.status, latest?.title, latest?.body].filter(Boolean).join(" ").toLowerCase();

  if (text.includes("blocker") || text.includes("blocked") || text.includes("failed")) return "danger";
  if (text.includes("guidance") || text.includes("human info") || text.includes("question")) return "warning";
  if (text.includes("review") || text.includes("validation")) return text.includes("completed") || text.includes("green") ? "success" : "info";
  return "muted";
}

function soloSessionLatestIsRedundant(session: SoloSession, latestText: string) {
  const title = session.title?.trim().toLowerCase();
  const latest = latestText.trim().toLowerCase();
  return !latest || Boolean(title && (latest === title || latest.includes(title)));
}
