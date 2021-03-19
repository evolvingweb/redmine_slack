# frozen_string_literal: true

require 'net/http'
require 'json'

# Slack class.
class Slack
  include Redmine::I18n

  def self.markup_format(text)
    text
  end

  def self.trim(original_msg, project)
    msg = original_msg
    trim_size = Slack.textfield_for_project(project, :text_trim_size).to_i

    if trim_size.positive?
      loop do
        msg = msg[0..trim_size]
        break unless /^.* (https?:\/\/[A-Za-z\.\d\/\:_\-\&\%\#\!]+)$/.match(msg)
        break if msg == original_msg
        # Restore original message and try again.
        msg = original_msg
        trim_size += 1
      end
    end
    msg
  end

  def self.default_url_options
    {only_path: true, script_name: Redmine::Utils.relative_url_root}
  end

  def self.speak(msg, channels, options, notification = nil)
    url = 'https://slack.com/api/chat.postMessage'
    token = RedmineSlack.settings[:redmine_slack_token]

    return if url.blank?
    return if channels.blank?
    return if token.blank?

    params = {
      text: msg,
      link_names: 1
    }

    params[:attachments] = [options[:attachment]] if options[:attachment]&.any?

    channels.each do |channel|
      uri = URI(url)
      params[:channel] = channel
      http_options = {use_ssl: uri.scheme == 'https'}
      http_options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless RedmineSlack.setting?(:redmine_slack_verify_ssl)

      begin
        req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
        req['Authorization'] = "Bearer #{token}"
        req.body = params.to_json
        Net::HTTP.start(uri.hostname, uri.port, http_options) do |http|
          response = http.request(req)
          body = response.body
          body_json = JSON.parse(body)
          notification.slack_message_id = body_json['ts']
          notification.slack_channel_id = body_json['channel']
          notification.save
          Rails.logger.warn(response) unless [Net::HTTPSuccess, Net::HTTPRedirection, Net::HTTPOK].include? response
        end
      rescue StandardError => e
        Rails.logger.warn("cannot connect to #{url}")
        Rails.logger.warn(e)
      end
    end
  end

  def self.update_message(msg, channel, options, notification = nil)
    url = 'https://slack.com/api/chat.update'
    token = RedmineSlack.settings[:redmine_slack_token]

    return if url.blank?
    return if channel.blank?
    return if token.blank?

    params = {
      ts: notification.slack_message_id,
      text: msg,
      link_names: 1
    }

    params[:attachments] = [options[:attachment]] if options[:attachment]&.any?

    uri = URI(url)
    params[:channel] = channel
    http_options = {use_ssl: uri.scheme == 'https'}
    http_options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless RedmineSlack.setting?(:redmine_slack_verify_ssl)
    begin
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req['Authorization'] = "Bearer #{token}"
      req.body = params.to_json
      Net::HTTP.start(uri.hostname, uri.port, http_options) do |http|
        response = http.request(req)
        notification.timestamp = Time.now.to_i
        notification.save
        Rails.logger.warn(response) unless [Net::HTTPSuccess, Net::HTTPRedirection, Net::HTTPOK].include? response
      end
    rescue StandardError => e
      Rails.logger.warn("cannot connect to #{url}")
      Rails.logger.warn(e)
    end
  end

  def self.object_url(obj)
    if Setting.host_name.to_s =~ %r{\A(https?\://)?(.+?)(\:(\d+))?(/.+)?\z}i
      host = Regexp.last_match(2)
      port = Regexp.last_match(4)
      prefix = Regexp.last_match(5)
      Rails.application.routes.url_for(
        obj.event_url(
          host: host,
          protocol: Setting.protocol,
          port: port,
          script_name: prefix
        )
      )
    else
      Rails.application.routes.url_for(
        obj.event_url(
          host: Setting.host_name,
          protocol: Setting.protocol,
          script_name: ''
        )
      )
    end
  end

  def self.textfield_for_project(proj, config)
    return if proj.blank?

    # project based
    pm = RedmineSlackSetting.find_by(project_id: proj.id)
    return pm.send(config) if !pm.nil? && pm.send(config).present?

    default_textfield(proj, config)
  end

  def self.default_textfield(proj, config)
    # parent project based
    parent_field = textfield_for_project(proj.parent, config)
    return parent_field if parent_field.present?
    return RedmineSlack.settings[config] if RedmineSlack.settings[config].present?

    ''
  end

  def self.channels_for_project(proj)
    return [] if proj.blank?

    # project based
    pm = RedmineSlackSetting.find_by(project_id: proj.id)
    if !pm.nil? && pm.redmine_slack_channel.present?
      return [] if pm.redmine_slack_channel == '-'

      return pm.redmine_slack_channel.split(',').map!(&:strip).uniq
    end
    default_project_channels(proj)
  end

  def self.default_project_channels(proj)
    # parent project based
    parent_channel = channels_for_project(proj.parent)
    return parent_channel if parent_channel.present?
    # system based
    if RedmineSlack.settings[:redmine_slack_channel].present? &&
       RedmineSlack.settings[:redmine_slack_channel] != '-'
      return RedmineSlack.settings[:redmine_slack_channel].split(',').map!(&:strip).uniq
    end

    []
  end

  def self.setting_for_project(proj, config)
    return false if proj.blank?

    @setting_found = 0
    # project based
    pm = RedmineSlackSetting.find_by(project_id: proj.id)
    unless pm.nil? || pm.send(config).zero?
      @setting_found = 1
      return false if pm.send(config) == 1
      return true if pm.send(config) == 2
      # 0 = use system based settings
    end
    default_project_setting(proj, config)
  end

  def self.default_project_setting(proj, config)
    if proj.present? && proj.parent.present?
      parent_setting = setting_for_project(proj.parent, config)
      return parent_setting if @setting_found == 1
    end
    # system based
    return true if RedmineSlack.settings[config].present? && RedmineSlack.setting?(config)

    false
  end

  def self.detail_to_field(detail, project)
    field_format = nil
    key = nil
    escape = true

    if detail.property == 'cf'
      key = begin
              CustomField.find(detail.prop_key).name
            rescue StandardError
              nil
            end
      title = key
      field_format = begin
                       CustomField.find(detail.prop_key).field_format
                     rescue StandardError
                       nil
                     end
    elsif detail.property == 'attachment'
      key = 'attachment'
      title = I18n.t :label_attachment
    else
      key = detail.prop_key.to_s.sub('_id', '')
      title = if key == 'parent'
                I18n.t "field_#{key}_issue"
              else
                I18n.t "field_#{key}"
              end
    end

    short = true
    value = detail.value.to_s

    case key
    when 'description'
      short = false
      value = Slack.trim(value, project)
    when 'title', 'subject'
      short = false
    when 'tracker'
      tracker = Tracker.find(detail.value)
      value = tracker.to_s if tracker.present?
    when 'project'
      project = Project.find(detail.value)
      value = project.to_s if project.present?
    when 'status'
      status = IssueStatus.find(detail.value)
      value = status.to_s if status.present?
    when 'priority'
      priority = IssuePriority.find(detail.value)
      value = priority.to_s if priority.present?
    when 'category'
      category = detail.value ? IssueCategory.find(detail.value) : ''
      value = category.to_s if category.present?
    when 'assigned_to'
      user = detail.value ? User.find(detail.value) : ''
      value = user.to_s if user.present?
    when 'fixed_version'
      fixed_version = detail.value ? Version.find(detail.value) : ''
      value = fixed_version.to_s if fixed_version.present?
    when 'attachment'
      attachment = Attachment.find(detail.prop_key)
      value = "<#{Slack.object_url attachment}|#{ERB::Util.html_escape(attachment.filename)}>" if attachment.present?
      escape = false
    when 'parent'
      issue = detail.value ? Issue.find(detail.value) : ''
      value = "<#{Slack.object_url issue}|#{ERB::Util.html_escape(issue)}>" if issue.present?
      escape = false
    end

    if detail.property == 'cf' && field_format == 'version'
      version = Version.find(detail.value)
      value = version.to_s if version.present?
    end

    value = if value.present?
              if escape
                ERB::Util.html_escape(value)
              else
                value
              end
            else
              '-'
            end

    result = {title: title, value: value}
    result[:short] = true if short
    result
  end

  def self.mentions(project, text)
    names = []
    Slack.textfield_for_project(project, :default_mentions)
         .split(',').each {|m| names.push m.strip}
    names += extract_usernames(text) unless text.nil?
    names.present? ? ' To: ' + names.uniq.join(', ') : nil
  end

  def self.extract_usernames(text)
    text = '' if text.nil?
    # slack usernames may only contain lowercase letters, numbers,
    # dashes, dots and underscores and must start with a letter or number.
    text.scan(/@[a-z0-9][a-z0-9_\-.]*/).uniq
  end

  def self.get_recent_notifications
    notifications = []
    # Get notifications sent in last 24 hours.
    notifications += RedmineSlackNotification.find_notification_by_type_within_timeframe('issue', 86_400)
    notifications += RedmineSlackNotification.find_notification_by_type_within_timeframe('issue-note', 86_400)
    notifications
  end

  def self.get_notification_replies(notification)
    url = 'https://slack.com/api/conversations.replies'
    token = RedmineSlack.settings[:redmine_slack_token]

    return if token.blank?

    params = {
      ts: notification.slack_message_id,
      channel: notification.slack_channel_id
    }

    uri = URI(url)
    uri.query = URI.encode_www_form(params)
    begin
      req = Net::HTTP::Get.new(uri, 'Content-Type' => 'application/json')
      req['Authorization'] = "Bearer #{token}"
      http_options = {use_ssl: uri.scheme == 'https'}
      http_options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless RedmineSlack.setting?(:redmine_slack_verify_ssl)
      Net::HTTP.start(uri.hostname, uri.port, http_options) do |http|
        response = http.request(req)
        body = response.body
        body_json = JSON.parse(body)
        body_json['messages'] || []
      end
    rescue StandardError => e
      Rails.logger.warn("cannot connect to #{url}")
      Rails.logger.warn(e)
    end
  end

  def self.get_user_email(slack_user_id)
    url = 'https://slack.com/api/users.info'
    token = RedmineSlack.settings[:redmine_slack_token]

    return if token.blank?

    params = {
      user: slack_user_id
    }

    uri = URI(url)
    uri.query = URI.encode_www_form(params)
    begin
      req = Net::HTTP::Get.new(uri, 'Content-Type' => 'application/json')
      req['Authorization'] = "Bearer #{token}"
      http_options = {use_ssl: uri.scheme == 'https'}
      http_options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless RedmineSlack.setting?(:redmine_slack_verify_ssl)
      Net::HTTP.start(uri.hostname, uri.port, http_options) do |http|
        response = http.request(req)
        body = response.body
        body_json = JSON.parse(body)
        if body_json['user']['profile'].key?('email')
          body_json['user']['profile']['email']
        end
      end
    rescue StandardError => e
      Rails.logger.warn("cannot connect to #{url}")
      Rails.logger.warn(e)
    end
  end

  def self.get_user_id(email)
    return 2 if email.nil?

    email_address = EmailAddress.find_by address: email
    return 2 if email_address.nil?

    email_address.user_id
  end

  def self.post_reply_to_redmine(message, issue_id)
    email = get_user_email(message['user'])
    author_id = get_user_id(email)
    journal = Journal.new
    journal.journalized_type = 'Issue'
    journal.journalized = Issue.find(issue_id)
    journal.user_id = author_id
    journal.notes = message['text']

    if message.key? 'files'
      message['files'].each do |file|
        url = file['url_private']
        file_content = get_attachment(url)
        attachments = []
        author = User.find(author_id)
        next if file_content.nil?

        attachment = Attachment.new(:file => file_content)
        attachment.container_id = issue_id
        attachment.container_type = 'Issue'
        attachment.author = author
        attachment.filename = file['title']
        attachment.content_type = file['mimetype']
        attachment.save
        journal.journalize_attachment(attachment, :added)
        attachments << attachment
      end
    end

    journal.save
    journal.journalized.save
    journal
  end

  def self.get_attachment(url)
    token = RedmineSlack.settings[:redmine_slack_token]

    return if token.blank?

    uri = URI(url)
    begin
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{token}"
      http_options = {use_ssl: uri.scheme == 'https'}
      http_options[:verify_mode] = OpenSSL::SSL::VERIFY_NONE unless RedmineSlack.setting?(:redmine_slack_verify_ssl)
      Net::HTTP.start(uri.hostname, uri.port, http_options) do |http|
        response = http.request(req)
        response.body
      end
    rescue StandardError => e
      Rails.logger.warn("cannot connect to #{url}")
      Rails.logger.warn(e)
    end
  end

  def self.post_slack_responses
    notifications = get_recent_notifications
    notifications.each do |notification|
      issue_id = notification.entity_id
      issue = Issue.find(issue_id)
      project = Project.find(issue.project_id)
      seconds = Slack.textfield_for_project(project, :replies_threshold).to_i || 0
      replies = get_notification_replies(notification)
      replies.each do |reply|
        next unless reply.key?('thread_ts') && reply['thread_ts'] != reply['ts']

        current_timestamp = Time.now.to_i
        timestamp = current_timestamp - seconds
        # Only act for replies within allowed "seconds".
        next if reply['ts'].to_i < timestamp

        post_reply_to_redmine(reply, issue_id)
      end
    end
  end
end
