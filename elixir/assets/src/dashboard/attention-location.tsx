import { LocateFixed } from "lucide-react";

import { Button } from "@/components/ui/button";
import type { AttentionJumpDestination, AttentionLocation, AttentionLocationLevel } from "./workstream-attention";
import { attentionJumpDestination } from "./workstream-attention";

export function AttentionLocationBar({
  location,
  onJump,
}: {
  location: AttentionLocation;
  onJump?: (destination: AttentionJumpDestination) => void;
}) {
  const requestDestination = attentionJumpDestination(location, "request");

  return (
    <div className="attention-location">
      <div className="attention-location__path">
        <span className="attention-location__repo" title={location.repo}>{location.repo}</span>
        {location.request ? (
          <LocationPart
            label={location.request.label}
            level="request"
            location={location}
            onJump={onJump}
          />
        ) : null}
        {location.groups.length || location.workPackage ? (
          <span className="attention-location__work">
            {location.groups.length ? (
              <LocationPart
                label={location.groups.at(-1)?.label || ""}
                level="group"
                location={location}
                onJump={onJump}
              />
            ) : null}
            {location.groups.length && location.workPackage ? <span aria-hidden="true"> &ndash; </span> : null}
            {location.workPackage ? (
              <LocationPart
                label={location.workPackage.label}
                level="work_package"
                location={location}
                onJump={onJump}
              />
            ) : null}
          </span>
        ) : null}
      </div>
      {requestDestination && onJump ? (
        <Button
          type="button"
          size="sm"
          variant="outline"
          className="attention-location__jump"
          aria-label={`Jump to ${attentionRequestLabel(location)}`}
          title="Jump to WorkRequest"
          onClick={() => onJump(requestDestination)}
        >
          <LocateFixed className="size-3.5" />
          WR
        </Button>
      ) : null}
    </div>
  );
}

function attentionRequestLabel(location: AttentionLocation) {
  return location.request?.label || "WorkRequest";
}

function LocationPart({
  label,
  level,
  location,
  onJump,
}: {
  label: string;
  level: AttentionLocationLevel;
  location: AttentionLocation;
  onJump?: (destination: AttentionJumpDestination) => void;
}) {
  const destination = attentionJumpDestination(location, level);
  if (!destination || !onJump) return <span title={label}>{label}</span>;

  return (
    <button
      type="button"
      className="attention-location__link"
      title={`Jump to ${label}`}
      onClick={() => onJump(destination)}
    >
      {label}
    </button>
  );
}
