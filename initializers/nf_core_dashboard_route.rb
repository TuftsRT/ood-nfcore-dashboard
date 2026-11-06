# /etc/ood/config/apps/dashboard/initializers/
# This is not a OOD recommended way to do this.  It can break the dashboard badly.
# Its only sane way to add this route outside of forking the built in dashboard.
#
# It does two things:
#   1. Adds the /nf-core route (NfPipelinesController#index).
#   2. Lets nf-core pipeline apps live in a sub folder of the sys apps dir
#      (default: /var/www/ood/apps/sys/ood-nfcore-pipelines/<app>) instead of
#      cluttering /var/www/ood/apps/sys/<app>.
#
# How (2) works: OOD resolves a batch connect token "sys/<app>" to
# SysRouter.base_path.join(<app>). We patch SysRouter#path so that when
# /var/www/ood/apps/sys/<app> does not exist but
# /var/www/ood/apps/sys/ood-nfcore-pipelines/<app> does, the nested folder is
# used. The token stays "sys/<app>", so launch URLs, session cache files and
# "My Interactive Sessions" keep working unchanged. SysRouter.apps is patched
# to also return the nested apps (so they appear in sys_apps for this page,
# "Recently Used" and pinned apps), while the container folder itself is
# dropped from the list. Apps in the top-level sys dir always win on a name
# clash.
#
# Override the location with NF_CORE_PIPELINES_DIR in
# /etc/ood/config/apps/dashboard/env if needed.

require 'pathname'
require 'set'

module NfCorePipelines
  DEFAULT_DIR = '/var/www/ood/apps/sys/ood-nfcore-pipelines'

  module_function

  def base_path
    Pathname.new(ENV.fetch('NF_CORE_PIPELINES_DIR', DEFAULT_DIR))
  end

  def readable_dir?(dir)
    dir.directory? && dir.readable? && dir.executable?
  end

  # Names of app directories inside the pipelines folder (same filtering rules
  # SysRouter uses: skip hidden dirs and "backup" dirs containing a dot).
  def app_names
    dir = base_path
    return [] unless readable_dir?(dir)

    dir.children
       .select(&:directory?)
       .map { |d| d.basename.to_s }
       .reject { |n| n.start_with?('.') || n.include?('.') }
       .sort
  rescue SystemCallError
    []
  end

  # Nested path for an app name, or nil if it is not there / not safe.
  def path_for(name)
    name = name.to_s
    return nil if name.empty? || name.include?('/') || name.start_with?('.')

    candidate = base_path.join(name)
    candidate.directory? ? candidate : nil
  end

  # True if +path+ is the pipelines container folder itself.
  def container?(path)
    Pathname.new(path).expand_path == base_path.expand_path
  rescue StandardError
    false
  end

  module SysRouterPath
    def path
      @path ||= begin
        default = self.class.base_path.join(name)
        if default.directory?
          default
        else
          NfCorePipelines.path_for(name) || default
        end
      end
    end
  end

  module SysRouterApps
    def apps
      top_level = super.reject { |app| NfCorePipelines.container?(app.path) }
      seen = top_level.map { |app| app.router.name.to_s }.to_set

      nested = NfCorePipelines.app_names
                              .reject { |n| seen.include?(n) }
                              .map { |n| OodApp.new(new(n)) }
                              .select(&:accessible?)

      top_level + nested
    end
  end
end

Rails.application.config.to_prepare do
  SysRouter.prepend(NfCorePipelines::SysRouterPath) unless SysRouter < NfCorePipelines::SysRouterPath
  unless SysRouter.singleton_class < NfCorePipelines::SysRouterApps
    SysRouter.singleton_class.prepend(NfCorePipelines::SysRouterApps)
  end
end

Rails.application.config.after_initialize do
  Rails.application.routes.append do
    get 'nf-core', to: 'nf_pipelines#index', as: 'nf_core'
  end

  Rails.application.routes_reloader.reload!
end
