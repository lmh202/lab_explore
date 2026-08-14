import { existsSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Keep observations small enough that one verbose command cannot consume the
// useful context. The complete command output still exists in Pi's temporary
// bash log when the built-in bash tool reports a fullOutputPath.
const MAX_TEXT_CHARS = 6000;
const HEAD_CHARS = 2200;
const TAIL_CHARS = 3200;
const COMPACTION_TRIGGER_TOKENS = 70000;
const MAX_IN_SESSION_RECOVERIES = 2;
const MAX_IDENTICAL_FAILURES = 3;
const MAX_IDENTICAL_CALLS = 3;

function readsWholeFileIntoMemory(command: string): boolean {
	return /\.read\s*\(\s*\)|\.readlines\s*\(\s*\)/i.test(command);
}

function truncateText(text: string): string {
	if (text.length <= MAX_TEXT_CHARS) return text;
	const omitted = text.length - HEAD_CHARS - TAIL_CHARS;
	return `${text.slice(0, HEAD_CHARS)}\n\n... [gemma-runtime-guard: ${omitted} characters omitted from a ${text.length}-character tool result] ...\n\n${text.slice(-TAIL_CHARS)}`;
}

function assistantText(message: any): string {
	if (!Array.isArray(message?.content)) return "";
	return message.content
		.map((block: any) => {
			if (block?.type === "text") return String(block.text ?? "");
			if (block?.type === "thinking") return String(block.thinking ?? "");
			return "";
		})
		.join("\n");
}

function signature(toolName: string, input: unknown): string {
	let serialized = "";
	try {
		if (toolName === "bash" && typeof (input as any)?.command === "string") {
			const command = String((input as any).command).replace(
				/^export GEMMA_RUNTIME_GUARD=1[^\n]*\n/,
				"",
			);
			serialized = JSON.stringify({ ...(input as any), command });
		} else {
			serialized = JSON.stringify(input);
		}
	} catch {
		serialized = String(input);
	}
	return `${toolName}:${serialized}`;
}

export default function gemmaRuntimeGuard(pi: ExtensionAPI) {
	const consecutiveFailures = new Map<string, number>();
	let lastCallSignature = "";
	let identicalCallStreak = 0;
	let compactionInFlight = false;
	let recoveryCount = 0;

	pi.on("tool_call", async (event) => {
		const key = signature(event.toolName, event.input);
		if (key === lastCallSignature) {
			identicalCallStreak += 1;
		} else {
			lastCallSignature = key;
			identicalCallStreak = 1;
		}
		if (identicalCallStreak > MAX_IDENTICAL_CALLS) {
			return {
				block: true,
				reason:
					"The identical tool call has already run three consecutive times. Inspect the existing result and take a materially different action.",
			};
		}
		if ((consecutiveFailures.get(key) ?? 0) >= MAX_IDENTICAL_FAILURES) {
			return {
				block: true,
				reason:
					"The identical tool call has already failed three times. Diagnose the error and use a materially different command or valid tool arguments instead of repeating it.",
			};
		}

		if (event.toolName === "bash") {
			const input = event.input as { command?: string };
			if (typeof input.command === "string" && readsWholeFileIntoMemory(input.command)) {
				return {
					block: true,
					reason:
						"This command reads an entire file into memory. Use a streaming iterator or bounded sample instead (for example, sum(1 for _ in file) to count lines).",
				};
			}
			if (typeof input.command === "string" && !input.command.includes("GEMMA_RUNTIME_GUARD=")) {
				input.command =
					"export GEMMA_RUNTIME_GUARD=1 TQDM_DISABLE=1 HF_HUB_DISABLE_PROGRESS_BARS=1 HF_DATASETS_DISABLE_PROGRESS_BARS=1 TRANSFORMERS_VERBOSITY=error;\n" +
					input.command;
			}
		}
	});

	pi.on("tool_result", async (event) => {
		const key = signature(event.toolName, event.input);
		if (event.isError) {
			consecutiveFailures.set(key, (consecutiveFailures.get(key) ?? 0) + 1);
		} else {
			consecutiveFailures.delete(key);
		}

		let changed = false;
		const content = event.content.map((block: any) => {
			if (block?.type !== "text" || typeof block.text !== "string") return block;
			const shortened = truncateText(block.text);
			if (shortened === block.text) return block;
			changed = true;
			return { ...block, text: shortened };
		});
		if (changed) return { content };
	});

	pi.on("turn_end", async (_event, ctx) => {
		const usage = ctx.getContextUsage();
		if (!usage || usage.tokens < COMPACTION_TRIGGER_TOKENS || compactionInFlight) return;
		compactionInFlight = true;
		ctx.compact({
			customInstructions:
				"Preserve the task contract, files created, commands that actually succeeded, current best validation result, unresolved errors, and exact remaining steps to produce submission/submission.csv. Omit verbose command output and repeated failed attempts.",
			onComplete: () => {
				compactionInFlight = false;
			},
			onError: () => {
				compactionInFlight = false;
			},
		});
	});

	pi.on("agent_end", async (event) => {
		if (recoveryCount >= MAX_IN_SESSION_RECOVERIES) return;
		const assistant = [...event.messages]
			.reverse()
			.find((message: any) => message?.role === "assistant") as any;
		if (!assistant) return;

		const text = assistantText(assistant);
		const malformedToolCall =
			/<\|?tool_call\|?>|<\|tool_response>|call:(?:bash|read|write|edit)\s*\{/i.test(text);
		const providerError = assistant.stopReason === "error";
		const submissionMissing = !existsSync(join(process.cwd(), "submission", "submission.csv"));
		const prematureStop = assistant.stopReason === "stop" && submissionMissing;
		if (!malformedToolCall && !providerError && !prematureStop) return;

		recoveryCount += 1;
		const reason = providerError
			? "The previous model request failed transiently."
			: malformedToolCall
				? "Your previous response printed tool-call syntax as text, so the command was not executed."
				: "The previous turn stopped before the required submission existed.";
		pi.sendUserMessage(
			`${reason} Continue from the files already present in the workspace. Use Pi's structured tools directly, keep command output bounded, and do not finish until submission/submission.csv exists and passes python validate_submission.py submission/submission.csv.`,
			{ deliverAs: "followUp" },
		);
	});
}
