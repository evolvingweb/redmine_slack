class RedmineSlackSetting < ActiveRecord::Base
    belongs_to :project

    validates :redmine_slack_url, url: { allow_blank: true, message: l(:error_redmine_slack_invalid_url) }
  
    def self.find_or_create(p_id)
      setting = RedmineSlackSetting.find_by(project_id: p_id)
      unless setting
        setting = RedmineSlackSetting.new
        setting.project_id = p_id
        #setting.save!
      end
  
      setting
    end
end