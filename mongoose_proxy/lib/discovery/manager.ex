defmodule Discovery.Manager do
  use ExRay, pre: :before_fun, post: :after_fun
  require Logger

  alias ExRay.Span
  alias MongooseProxy.CloudstateEntity
  alias Google.Protobuf.FileDescriptorSet

  @protocol_minor_version 1
  @protocol_major_version 0
  @proxy_name "mongoose-proxy"
  @supported_entity_types ["cloudstate.eventsourced.EventSourced"]

  # Generates a request id
  @req_id :os.system_time(:milli_seconds) |> Integer.to_string() |> IO.inspect()

  @trace kind: :normal
  def discover(channel) do
    message =
      Cloudstate.ProxyInfo.new(
        protocol_major_version: @protocol_minor_version,
        protocol_minor_version: @protocol_minor_version,
        proxy_name: @proxy_name,
        proxy_version: Application.spec(:mongoose_proxy, :vsn),
        supported_entity_types: @supported_entity_types
      )

    channel
    |> Cloudstate.EntityDiscovery.Stub.discover(message)
    |> handle_response
  end

  @trace kind: :critical
  def report_error(channel, error) do
    {_, response} =
      channel
      |> Cloudstate.EntityDiscovery.Stub.report_error(error)

    Logger.info("User function report error reply #{inspect(response)}")
    response
  end

  defp handle_response(response) do
    extract_message(response)
    |> validate
    |> register_entities
  end

  defp register_entities({:ok, message}) do
    # TODO: Registry entities here
    entities = message.entities
    descriptor = FileDescriptorSet.decode(message.proto)
    file_descriptors = descriptor.file
    Logger.debug("file_descriptors -> #{inspect(file_descriptors)}")

    user_entities =
      entities
      |> Flow.from_enumerable()
      |> Flow.map(&parse_entity(&1, file_descriptors))
      |> Enum.to_list()

    Logger.debug("Cloudstate Entities: #{inspect(user_entities)}.")
    user_entities
  end

  defp parse_entity(entity, file_descriptors) do
    messages =
      file_descriptors
      |> Flow.from_enumerable()
      |> Flow.map(&extract_messages/1)
      |> Enum.to_list()

    services =
      file_descriptors
      |> Flow.from_enumerable()
      |> Flow.map(&extract_services/1)
      |> Enum.to_list()

    entity = %CloudstateEntity{
      node: Node.self(),
      entity_type: entity.entity_type,
      service_name: entity.service_name,
      persistence_id: entity.persistence_id,
      messages: messages,
      services: services
    }
  end

  defp extract_messages(file) do
    file.message_type
    |> Flow.from_enumerable()
    |> Flow.map(&to_message_item/1)
    |> Enum.to_list()
  end

  defp extract_services(file) do
    file.service
    |> Flow.from_enumerable()
    |> Flow.map(&to_service_item/1)
    |> Enum.to_list()
  end

  defp to_message_item(message) do
    %{name: message.name}
  end

  defp to_service_item(service) do
    %{name: service.name}
  end

  defp validate(message) do
    entities = message.entities

    if Enum.empty?(entities) do
      Logger.error("No entities were reported by the discover call!")
      raise "No entities were reported by the discover call!"
    end

    entities
    |> Enum.each(fn entity ->
      if !Enum.member?(@supported_entity_types, entity.entity_type) do
        Logger.error("This proxy not support entities of type #{entity.entity_type}")
        raise "This proxy not support entities of type #{entity.entity_type}"
      end
    end)

    if !is_binary(message.proto) do
      Logger.error("No descriptors found in EntitySpec")
      raise "No descriptors found in EntitySpec"
    end

    if String.trim(message.service_info.service_name) == "" do
      Logger.warn("Service Info does not provide a service name")
    end

    {:ok, message}
  end

  defp extract_message(response) do
    {:ok, message} = response

    case response do
      ok ->
        Logger.info("Received EntitySpec from user function with info: #{inspect(message)}")
        message

      _ ->
        Logger.error("Error -> #{inspect(response)}")
    end
  end

  defp before_fun(ctx) do
    ctx.target
    |> Span.open(@req_id)
    |> :otter.tag(:kind, ctx.meta[:kind])
    |> :otter.tag(:component, __MODULE__)
    |> :otter.log(">>> #{ctx.target} with #{ctx.args |> inspect}")
  end

  defp after_fun(ctx, span, res) do
    span
    |> :otter.log("<<< #{ctx.target} returned #{res |> inspect}")
    |> Span.close(@req_id)
  end
end
