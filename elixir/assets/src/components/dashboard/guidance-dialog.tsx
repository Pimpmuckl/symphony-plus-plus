import { ChevronDown, CircleDot, Loader2, Send } from "lucide-react";
import { useId, useMemo, useReducer } from "react";

import { Button } from "@/components/ui/button";
import { Collapsible, CollapsibleContent } from "@/components/ui/collapsible";
import { DetailCopyButton } from "@/components/dashboard/detail-copy-button";
import { MarkdownBlock } from "@/components/dashboard/markdown-block";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";
import { guidanceCopyText } from "@/dashboard/detail-copy";
import { AttentionLocationBar } from "@/dashboard/attention-location";
import type { AttentionJumpDestination, AttentionLocation } from "@/dashboard/workstream-attention";
import type {
  DecisionOption,
  DecisionPrompt,
  GuidanceAnswerSubmission,
  GuidanceItem,
} from "@/types/dashboard";

const CUSTOM_CHOICE = "__custom_redirect__";

type GuidanceDialogState = {
  selectedChoice: string;
  notes: Record<string, string>;
  openNotes: Record<string, boolean>;
  submitting: boolean;
  error: string | null;
};

type GuidanceDialogAction =
  | { type: "select"; optionId: string }
  | { type: "toggleNote"; optionId: string }
  | { type: "focusNote"; optionId: string }
  | { type: "note"; optionId: string; value: string }
  | { type: "submitting"; submitting: boolean }
  | { type: "error"; error: string | null };

const initialGuidanceDialogState: GuidanceDialogState = {
  selectedChoice: "",
  notes: {},
  openNotes: {},
  submitting: false,
  error: null,
};

function guidanceDialogReducer(state: GuidanceDialogState, action: GuidanceDialogAction): GuidanceDialogState {
  switch (action.type) {
    case "select":
      return { ...state, selectedChoice: action.optionId };
    case "toggleNote":
      return {
        ...state,
        selectedChoice: action.optionId,
        openNotes: { ...state.openNotes, [action.optionId]: !state.openNotes[action.optionId] },
      };
    case "focusNote":
      return {
        ...state,
        selectedChoice: action.optionId,
        openNotes: action.optionId === CUSTOM_CHOICE ? state.openNotes : { ...state.openNotes, [action.optionId]: true },
      };
    case "note":
      return {
        ...state,
        selectedChoice: action.optionId,
        notes: { ...state.notes, [action.optionId]: action.value },
        openNotes: action.optionId === CUSTOM_CHOICE ? state.openNotes : { ...state.openNotes, [action.optionId]: true },
      };
    case "submitting":
      return { ...state, submitting: action.submitting, error: action.submitting ? null : state.error };
    case "error":
      return { ...state, error: action.error };
  }
}

function initialGuidanceDialogStateWithChoice(selectedChoice: string): GuidanceDialogState {
  return { ...initialGuidanceDialogState, selectedChoice };
}

export function GuidanceDialog({
  item,
  location,
  onJumpToAttention,
  onOpenChange,
  onSubmitAnswer,
}: {
  item: GuidanceItem | null;
  location?: AttentionLocation;
  onJumpToAttention?: (destination: AttentionJumpDestination) => void;
  onOpenChange: (open: boolean) => void;
  onSubmitAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
}) {
  return (
    <Dialog open={Boolean(item)} onOpenChange={onOpenChange}>
      <DialogContent className="dashboard-dialog-content">
        {item ? (
          <GuidanceDialogBody
            key={guidanceDialogStateKey(item)}
            item={item}
            location={location}
            onJumpToAttention={onJumpToAttention}
            onOpenChange={onOpenChange}
            onSubmitAnswer={onSubmitAnswer}
          />
        ) : null}
      </DialogContent>
    </Dialog>
  );
}

export function GuidanceDialogBody({
  item,
  location,
  onJumpToAttention,
  onOpenChange,
  onSubmitAnswer,
}: {
  item: GuidanceItem;
  location?: AttentionLocation;
  onJumpToAttention?: (destination: AttentionJumpDestination) => void;
  onOpenChange: (open: boolean) => void;
  onSubmitAnswer: (item: GuidanceItem, submission: GuidanceAnswerSubmission) => Promise<void>;
}) {
  const options = useMemo(() => guidanceOptions(item.prompt), [item.prompt]);
  const copyText = useMemo(() => guidanceCopyText(item, options), [item, options]);
  const radioGroupId = useId();
  const [state, dispatch] = useReducer(guidanceDialogReducer, options[0]?.id || CUSTOM_CHOICE, initialGuidanceDialogStateWithChoice);
  const radioGroupName = `${radioGroupId}-guidance-choice`;

  function selectChoice(optionId: string) {
    dispatch({ type: "select", optionId });
  }

  function toggleNote(optionId: string) {
    dispatch({ type: "toggleNote", optionId });
  }

  function focusNote(optionId: string) {
    dispatch({ type: "focusNote", optionId });
  }

  function updateNote(optionId: string, value: string) {
    dispatch({ type: "note", optionId, value });
  }

  async function submitAnswer() {
    if (!item || !state.selectedChoice) return;

    dispatch({ type: "submitting", submitting: true });

    try {
      const answerNote = state.notes[state.selectedChoice] || "";
      await onSubmitAnswer(item, {
        answer_choice: state.selectedChoice,
        answer_note: answerNote,
        answer: state.selectedChoice === CUSTOM_CHOICE ? answerNote : undefined,
      });
    } catch (caught) {
      dispatch({ type: "error", error: caught instanceof Error ? caught.message : "Answer was not recorded" });
    } finally {
      dispatch({ type: "submitting", submitting: false });
    }
  }

  return (
    <>
      <DialogHeader data-guidance-section style={{ animationDelay: "35ms" }}>
        <div className="flex min-w-0 items-start justify-between gap-3">
          <div className="min-w-0">
            <DialogTitle className="pr-6">{item.prompt?.tl_dr || item.title}</DialogTitle>
            <DialogDescription className="mt-1 truncate">{item.repo}</DialogDescription>
          </div>
          <div className="shrink-0 pr-6">
            <DetailCopyButton label="Copy guidance details" text={copyText} />
          </div>
        </div>
      </DialogHeader>
      {location ? <AttentionLocationBar location={location} onJump={onJumpToAttention} /> : null}
      <div className="grid gap-4">
        <section className="rounded-lg border bg-muted/40 p-4" data-guidance-section style={{ animationDelay: "70ms" }}>
          <p className="text-sm font-medium">TL;DR</p>
          <p className="mt-2 text-sm text-muted-foreground">{item.prompt?.tl_dr || item.title}</p>
        </section>
        <section className="rounded-lg border p-4" data-guidance-section style={{ animationDelay: "95ms" }}>
          <p className="text-sm font-medium">Details</p>
          <MarkdownBlock className="mt-2 text-sm" value={item.prompt?.details || item.detail} />
        </section>
        <fieldset className="m-0 grid gap-3 border-0 p-0" data-guidance-section style={{ animationDelay: "120ms" }}>
          <legend className="sr-only">Guidance options</legend>
          {options.map((option, index) => {
            const isCustom = option.id === CUSTOM_CHOICE;
            const selected = state.selectedChoice === option.id;
            const noteOpen = isCustom || Boolean(state.openNotes[option.id]);
            const optionInputId = `${radioGroupId}-${option.id}`;

            return (
              <div
                key={option.id}
                className={cn(
                  "guidance-option rounded-lg border p-4 text-left outline-none transition-colors focus-within:ring-2 focus-within:ring-ring",
                  selected ? "border-primary bg-primary/5" : "bg-background hover:border-primary/50",
                )}
                style={{ animationDelay: `${index * 35}ms` }}
              >
                <input
                  id={optionInputId}
                  className="sr-only"
                  type="radio"
                  name={radioGroupName}
                  checked={selected}
                  onChange={() => selectChoice(option.id)}
                />
                <div className="min-w-0">
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <label htmlFor={optionInputId} className="flex min-w-0 cursor-pointer items-start gap-3">
                      <CircleDot className={cn("mt-0.5 size-4 shrink-0", selected ? "text-primary" : "text-muted-foreground")} />
                      <span className="min-w-0">
                        <span className="block text-sm font-semibold">{option.label}</span>
                        {option.description ? <span className="mt-1 block text-sm text-muted-foreground">{option.description}</span> : null}
                      </span>
                    </label>
                    {!isCustom ? (
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        className="button-lift h-8 shrink-0 justify-start px-2 text-xs"
                        aria-expanded={noteOpen}
                        onClick={() => toggleNote(option.id)}
                      >
                        <ChevronDown className={cn("size-3.5 transition-transform duration-200", noteOpen && "rotate-180")} />
                        Add Extra Note
                      </Button>
                    ) : null}
                  </div>
                  {!isCustom ? <ProsCons option={option} /> : null}
                  <Collapsible open={noteOpen}>
                    <CollapsibleContent className="collapsible-content option-note-content">
                      <div className="px-0.5 pb-0.5 pt-3">
                        <Label className="block text-xs text-muted-foreground">
                          {isCustom ? "None of the above, do this instead:" : "Extra note"}
                        </Label>
                        <Textarea
                          className="mt-1 min-h-[72px]"
                          placeholder={isCustom ? "Tell the architect what to do instead." : "Add optional Markdown context for this answer."}
                          value={state.notes[option.id] || ""}
                          onFocus={() => focusNote(option.id)}
                          onChange={(event) => updateNote(option.id, event.target.value)}
                          onClick={() => focusNote(option.id)}
                        />
                      </div>
                    </CollapsibleContent>
                  </Collapsible>
                </div>
              </div>
            );
          })}
        </fieldset>
        {state.error ? <p className="text-sm text-destructive">{state.error}</p> : null}
      </div>
      <DialogFooter>
        <Button variant="outline" onClick={() => onOpenChange(false)}>
          Cancel
        </Button>
        <Button onClick={submitAnswer} disabled={state.submitting || (state.selectedChoice === CUSTOM_CHOICE && !state.notes[state.selectedChoice]?.trim())}>
          {state.submitting ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />}
          Answer
        </Button>
      </DialogFooter>
    </>
  );
}

function guidanceDialogStateKey(item: GuidanceItem) {
  return `${item.source}:${item.id}:${guidancePromptKey(item.prompt)}`;
}

function guidancePromptKey(prompt?: DecisionPrompt | null) {
  return guidanceOptions(prompt)
    .map((option) =>
      [option.id, option.label, option.description || "", option.answer || "", (option.pros || []).join(","), (option.cons || []).join(",")].join("\u001f"),
    )
    .join("\u001e");
}

function ProsCons({ option }: { option: DecisionOption }) {
  if (!option.pros?.length && !option.cons?.length) return null;

  return (
    <div className="mt-3 grid gap-2 md:grid-cols-2">
      <div className="rounded-md bg-emerald-50 p-3 text-xs text-emerald-800 dark:bg-emerald-950/50 dark:text-emerald-200">
        <p className="font-semibold">Pros</p>
        <ul className="mt-1 space-y-1">
          {(option.pros || ["No specific pros recorded"]).map((pro) => (
            <li key={pro}>{pro}</li>
          ))}
        </ul>
      </div>
      <div className="rounded-md bg-rose-50 p-3 text-xs text-rose-800 dark:bg-rose-950/50 dark:text-rose-200">
        <p className="font-semibold">Cons</p>
        <ul className="mt-1 space-y-1">
          {(option.cons || ["No specific cons recorded"]).map((con) => (
            <li key={con}>{con}</li>
          ))}
        </ul>
      </div>
    </div>
  );
}

function guidanceOptions(prompt?: DecisionPrompt | null): DecisionOption[] {
  const options = prompt?.options?.length
    ? prompt.options
    : [
        {
          id: "continue",
          label: "Continue",
          description: "Proceed with the proposed direction.",
          pros: ["Fastest path forward"],
          cons: ["Can preserve ambiguity"],
          answer: "Continue with the proposed direction.",
        },
        {
          id: "narrow",
          label: "Narrow scope",
          description: "Reduce or clarify the scope before implementation.",
          pros: ["Lower delivery risk"],
          cons: ["Adds clarification time"],
          answer: "Narrow the scope before continuing.",
        },
      ];

  return [
    ...options,
    {
      id: CUSTOM_CHOICE,
      label: "None of the above, do this instead:",
      description: "Give the architect or worker a different direction.",
    },
  ];
}
