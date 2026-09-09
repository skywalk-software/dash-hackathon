/** Forward resolved task metadata; UI must not infer references from a recording's raw gestures. */
export function presentJob({id, state, task, result, error, requestId}) {
  return {id, state, recordingID: requestId?.split(':')[0], instruction: task.instruction,
    operation: task.operation, references: task.references, context: task.context,
    working_area: task.working_area, outcome: result?.status,
    answer: result?.answer, error: error || result?.reason};
}
