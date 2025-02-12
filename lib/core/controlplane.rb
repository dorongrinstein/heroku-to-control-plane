# frozen_string_literal: true

class Controlplane # rubocop:disable Metrics/ClassLength
  attr_reader :config, :api, :gvc, :org

  def initialize(config)
    @config = config
    @api = ControlplaneApi.new
    @gvc = config.app
    @org = config.org
  end

  # profile

  def profile_switch(profile)
    ENV["CPLN_PROFILE"] = profile
  end

  def profile_exists?(profile)
    cmd = "cpln profile get #{profile} -o yaml"
    perform_yaml(cmd).length.positive?
  end

  def profile_create(profile, token)
    cmd = "cpln profile create #{profile} --token #{token}"
    cmd += " > /dev/null" if Shell.tmp_stderr
    perform!(cmd)
  end

  def profile_delete(profile)
    cmd = "cpln profile delete #{profile}"
    cmd += " > /dev/null" if Shell.tmp_stderr
    perform!(cmd)
  end

  # image

  def image_build(image, dockerfile:, build_args: [], push: true)
    cmd = "docker build -t #{image} -f #{dockerfile}"
    build_args.each { |build_arg| cmd += " --build-arg #{build_arg}" }
    cmd += " #{config.app_dir}"
    perform!(cmd)

    image_push(image) if push
  end

  def image_query(app_name = config.app, org_name = config.org)
    cmd = "cpln image query --org #{org_name} -o yaml --max -1 --prop repository=#{app_name}"
    perform_yaml(cmd)
  end

  def image_delete(image)
    api.image_delete(org: org, image: image)
  end

  def image_login(org_name = config.org)
    cmd = "cpln image docker-login --org #{org_name}"
    cmd += " > /dev/null 2>&1" if Shell.tmp_stderr
    perform!(cmd)
  end

  def image_pull(image)
    cmd = "docker pull #{image}"
    cmd += " > /dev/null" if Shell.tmp_stderr
    perform!(cmd)
  end

  def image_tag(old_tag, new_tag)
    cmd = "docker tag #{old_tag} #{new_tag}"
    cmd += " > /dev/null" if Shell.tmp_stderr
    perform!(cmd)
  end

  def image_push(image)
    cmd = "docker push #{image}"
    cmd += " > /dev/null" if Shell.tmp_stderr
    perform!(cmd)
  end

  # gvc

  def fetch_gvcs
    api.gvc_list(org: org)
  end

  def gvc_query(app_name = config.app)
    # When `match_if_app_name_starts_with` is `true`, we query for any gvc containing the name,
    # otherwise we query for a gvc with the exact name.
    op = config.current[:match_if_app_name_starts_with] ? "~" : "="

    cmd = "cpln gvc query --org #{org} -o yaml --prop name#{op}#{app_name}"
    perform_yaml(cmd)
  end

  def fetch_gvc(a_gvc = gvc, a_org = org)
    api.gvc_get(gvc: a_gvc, org: a_org)
  end

  def fetch_gvc!(a_gvc = gvc)
    gvc_data = fetch_gvc(a_gvc)
    return gvc_data if gvc_data

    raise "Can't find app '#{gvc}', please create it with 'cpl setup-app -a #{config.app}'."
  end

  def gvc_delete(a_gvc = gvc)
    api.gvc_delete(gvc: a_gvc, org: org)
  end

  # workload

  def fetch_workloads(a_gvc = gvc)
    api.workload_list(gvc: a_gvc, org: org)
  end

  def fetch_workloads_by_org(a_org = org)
    api.workload_list_by_org(org: a_org)
  end

  def fetch_workload(workload)
    api.workload_get(workload: workload, gvc: gvc, org: org)
  end

  def fetch_workload!(workload)
    workload_data = fetch_workload(workload)
    return workload_data if workload_data

    raise "Can't find workload '#{workload}', please create it with 'cpl apply-template #{workload} -a #{config.app}'."
  end

  def query_workloads(workload, partial_match: false)
    op = partial_match ? "~" : "="

    api.query_workloads(org: org, gvc: gvc, workload: workload, op_type: op)
  end

  def workload_get_replicas(workload, location:)
    cmd = "cpln workload get-replicas #{workload} #{gvc_org} --location #{location} -o yaml"
    perform_yaml(cmd)
  end

  def workload_get_replicas_safely(workload, location:)
    cmd = "cpln workload get-replicas #{workload} #{gvc_org} --location #{location} -o yaml 2> /dev/null"
    result = `#{cmd}`
    $CHILD_STATUS.success? ? YAML.safe_load(result) : nil
  end

  def fetch_workload_deployments(workload)
    api.workload_deployments(workload: workload, gvc: gvc, org: org)
  end

  def workload_set_image_ref(workload, container:, image:)
    cmd = "cpln workload update #{workload} #{gvc_org}"
    cmd += " --set spec.containers.#{container}.image=/org/#{config.org}/image/#{image}"
    cmd += " > /dev/null" if Shell.tmp_stderr
    perform!(cmd)
  end

  def set_workload_env_var(workload, container:, name:, value:)
    data = fetch_workload!(workload)
    data["spec"]["containers"].each do |container_data|
      next unless container_data["name"] == container

      container_data["env"].each do |env_data|
        next unless env_data["name"] == name

        env_data["value"] = value
      end
    end

    api.update_workload(org: org, gvc: gvc, workload: workload, data: data)
  end

  def set_workload_suspend(workload, value)
    data = fetch_workload!(workload)
    data["spec"]["defaultOptions"]["suspend"] = value

    api.update_workload(org: org, gvc: gvc, workload: workload, data: data)
  end

  def workload_force_redeployment(workload)
    cmd = "cpln workload force-redeployment #{workload} #{gvc_org}"
    cmd += " > /dev/null" if Shell.tmp_stderr
    perform!(cmd)
  end

  def delete_workload(workload)
    api.delete_workload(org: org, gvc: gvc, workload: workload)
  end

  def workload_connect(workload, location:, container: nil, shell: nil)
    cmd = "cpln workload connect #{workload} #{gvc_org} --location #{location}"
    cmd += " --container #{container}" if container
    cmd += " --shell #{shell}" if shell
    perform!(cmd)
  end

  def workload_exec(workload, location:, container: nil, command: nil)
    cmd = "cpln workload exec #{workload} #{gvc_org} --location #{location}"
    cmd += " --container #{container}" if container
    cmd += " -- #{command}"
    perform!(cmd)
  end

  # domain

  def find_domain_route(data)
    port = data["spec"]["ports"].find { |current_port| current_port["number"] == 80 || current_port["number"] == 443 }
    return nil if port.nil? || port["routes"].nil?

    route = port["routes"].find { |current_route| current_route["prefix"] == "/" }
    return nil if route.nil?

    route
  end

  def find_domain_for(workloads)
    domains = api.list_domains(org: org)["items"]
    domains.find do |domain_data|
      route = find_domain_route(domain_data)
      next false if route.nil?

      workloads.any? { |workload| route["workloadLink"].split("/").last == workload }
    end
  end

  def get_domain_workload(data)
    route = find_domain_route(data)
    route["workloadLink"].split("/").last
  end

  def set_domain_workload(data, workload)
    route = find_domain_route(data)
    route["workloadLink"] = "/org/#{org}/gvc/#{gvc}/workload/#{workload}"

    api.update_domain(org: org, domain: data["name"], data: data)
  end

  # logs

  def logs(workload:)
    cmd = "cpln logs '{workload=\"#{workload}\"}' --org #{org} -t -o raw --limit 200"
    perform!(cmd)
  end

  def log_get(workload:, from:, to:)
    api.log_get(org: org, gvc: gvc, workload: workload, from: from, to: to)
  end

  # apply

  def apply(data) # rubocop:disable Metrics/MethodLength
    Tempfile.create do |f|
      f.write(data.to_yaml)
      f.rewind
      cmd = "cpln apply #{gvc_org} --file #{f.path} > /dev/null"
      if Shell.tmp_stderr
        cmd += " 2> #{Shell.tmp_stderr.path}"
        perform(cmd)
      else
        perform!(cmd)
      end
    end
  end

  private

  def perform(cmd)
    system(cmd)
  end

  def perform!(cmd)
    system(cmd) || exit(false)
  end

  def perform_yaml(cmd)
    result = `#{cmd}`
    $CHILD_STATUS.success? ? YAML.safe_load(result) : exit(false)
  end

  def gvc_org
    "--gvc #{gvc} --org #{org}"
  end
end
