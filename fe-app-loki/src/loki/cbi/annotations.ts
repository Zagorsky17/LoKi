interface AnnotationSpan {
  start: number;
  end: number;
}

export interface Annotation extends AnnotationSpan {
  message: string;
}

interface PendingAnnotation extends AnnotationSpan {
  messages: string[];
}

export type AnnotationMap = Map<string, PendingAnnotation>;

function createAnnotationKey(annotation: AnnotationSpan): string {
  return `${annotation.start}:${annotation.end}`;
}

export function addAnnotationIssue(
  annotationMap: AnnotationMap,
  annotation: AnnotationSpan,
  message: string,
): void {
  const key = createAnnotationKey(annotation);
  const existing = annotationMap.get(key);
  if (existing) {
    if (!existing.messages.includes(message)) {
      existing.messages.push(message);
    }
    return;
  }

  annotationMap.set(key, {
    start: annotation.start,
    end: annotation.end,
    messages: [message],
  });
}

export function finalizeAnnotations(
  annotationMap: AnnotationMap,
): Annotation[] {
  return Array.from(annotationMap.values())
    .map((annotation) => ({
      start: annotation.start,
      end: annotation.end,
      message: annotation.messages.join('; '),
    }))
    .sort((left, right) => left.start - right.start || left.end - right.end);
}
