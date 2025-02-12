# frozen_string_literal: true

module Command
  class Delete < Base
    NAME = "delete"
    OPTIONS = [
      app_option(required: true),
      skip_confirm_option
    ].freeze
    DESCRIPTION = "Deletes the whole app (GVC with all workloads and all images)"
    LONG_DESCRIPTION = <<~DESC
      - Deletes the whole app (GVC with all workloads and all images)
      - Will ask for explicit user confirmation
    DESC

    def call
      return unless confirm_delete

      delete_gvc
      delete_images
    end

    private

    def confirm_delete
      return true if config.options[:yes]

      confirmed = Shell.confirm("Are you sure you want to delete '#{config.app}'?")
      return false unless confirmed

      progress.puts
      true
    end

    def delete_gvc
      return progress.puts("App '#{config.app}' does not exist.") if cp.fetch_gvc.nil?

      step("Deleting app '#{config.app}'") do
        cp.gvc_delete
      end
    end

    def delete_images
      images = cp.image_query["items"]
                 .filter_map { |item| item["name"] if item["name"].start_with?("#{config.app}:") }

      return progress.puts("No images to delete.") unless images.any?

      images.each do |image|
        step("Deleting image '#{image}'") do
          cp.image_delete(image)
        end
      end
    end
  end
end
