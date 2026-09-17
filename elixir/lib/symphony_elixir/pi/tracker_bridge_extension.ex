defmodule SymphonyElixir.Pi.TrackerBridgeExtension do
  @moduledoc false

  @extension_filename "pi-tracker-bridge.mjs"

  @spec write(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def write(workspace) when is_binary(workspace) do
    directory = Path.join(workspace, ".symphony")
    path = Path.join(directory, @extension_filename)
    temporary_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary_path, source()),
         :ok <- File.chmod(temporary_path, 0o600),
         :ok <- File.rename(temporary_path, path) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm(temporary_path)
        {:error, reason}
    end
  rescue
    error in [ArgumentError, File.Error] -> {:error, error}
  end

  defp source do
    ~S"""
    const bridgeUrl = process.env.SYMPHONY_PI_TRACKER_BRIDGE_URL;
    const capability = process.env.SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY;
    const encodedSpecs = process.env.SYMPHONY_PI_TRACKER_BRIDGE_TOOL_SPECS;

    delete process.env.SYMPHONY_PI_TRACKER_BRIDGE_URL;
    delete process.env.SYMPHONY_PI_TRACKER_BRIDGE_CAPABILITY;
    delete process.env.SYMPHONY_PI_TRACKER_BRIDGE_TOOL_SPECS;

    function decodeSpecs(value) {
      if (!value) return [];
      return JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    }

    function textOutput(result) {
      if (result && typeof result.output === "string") return result.output;
      return JSON.stringify(result ?? { error: { message: "Empty Symphony tracker response." } }, null, 2);
    }

    export default function symphonyTrackerBridge(pi) {
      if (!bridgeUrl || !capability || !encodedSpecs) {
        throw new Error("Symphony tracker bridge bootstrap is incomplete");
      }

      for (const spec of decodeSpecs(encodedSpecs)) {
        const isHandoff = spec.name === "symphony_handoff";

        pi.registerTool({
          name: spec.name,
          label: isHandoff ? "Symphony Handoff" : (spec.label ?? spec.name),
          description: spec.description,
          promptSnippet: isHandoff
            ? "Stage the current issue's non-active handoff until Symphony records final turn evidence"
            : spec.description,
          promptGuidelines: isHandoff
            ? [
                "Use symphony_handoff for the final tracker state transition after all work, validation, and tracker notes are complete.",
                "Do not move the current issue out of an active state with another tracker tool; symphony_handoff lets Symphony save the final receipt first.",
              ]
            : [
                `Use ${spec.name} for provider-native tracker operations, but use symphony_handoff for the final non-active state transition.`,
              ],
          parameters: spec.inputSchema,
          async execute(_toolCallId, params, signal) {
            try {
              const response = await fetch(bridgeUrl, {
                method: "POST",
                headers: {
                  authorization: `Bearer ${capability}`,
                  "content-type": "application/json",
                },
                body: JSON.stringify({ tool: spec.name, arguments: params }),
                signal,
              });

              const result = await response.json();
              const output = textOutput(result);

              return {
                content: [{ type: "text", text: output }],
                details: { success: result?.success === true, source: "symphony_tracker_bridge" },
                isError: response.status !== 200 || result?.success !== true,
              };
            } catch (error) {
              const message = error instanceof Error ? error.message : String(error);
              return {
                content: [{ type: "text", text: `Symphony tracker bridge failed: ${message}` }],
                details: { success: false, source: "symphony_tracker_bridge" },
                isError: true,
              };
            }
          },
        });
      }
    }
    """
  end
end
