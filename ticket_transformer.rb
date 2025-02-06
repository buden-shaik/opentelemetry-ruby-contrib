class ActivitiesLog::Transformers::TicketTransformer < ActivitiesLog::Transformers::ActivityTransformer
  include DateTimeFormatter
  include ActivitiesLog::Transformers::Modules::Timesheet
  include ActivitiesLog::Transformers::Modules::Task
  include Ams::AlertActivityTransformer
  include Ocs::ActivityTransformer
  include StatusPage::ActivityTransformer
  include ActivitiesLog::Transformers::ActivityTransformerHelper
  include Itil::RouteHelper
  include Ticket::PostIncidentReport::ActivityTransformer
  include Communication::ActivityTransformer

	def transform
		unless @response["data"].blank?
			start_token = @response["links"].blank? ? "" : extract_start_token(@response["links"][0]["href"])
			@response   = @response["data"]
		end
		parsed_activities = []
		@response.each do |activity|
			newrelic_begin_rescue {
				activity = activity.with_indifferent_access
				if OCS_PAYLOAD_TYPES.include? activity[:payload_type]
					ocs_parsed_activity = ocs_activity_transformer(activity)
					next if ocs_parsed_activity[:content].blank?
					append_timestamp(ocs_parsed_activity, activity)
					parsed_activities.push(ocs_parsed_activity)
				elsif STATUS_PAGE_PAYLOAD_TYPES.include?(activity[:payload_type])
					status_page_parsed_activity = status_page_activity_transformer(activity)
					next if status_page_parsed_activity[:content].blank?
					append_timestamp(status_page_parsed_activity, activity)
					parsed_activities.push(status_page_parsed_activity)
        elsif POST_INCIDENT_REPORT_PAYLOAD_TYPES.include?(activity[:payload_type])
          pir_parsed_activity = post_incident_report_activity_transformer(activity)
          next if pir_parsed_activity[:content].blank?
          append_timestamp(pir_parsed_activity, activity)
          parsed_activities.push(pir_parsed_activity)
        elsif COMMUNICATION_PAYLOAD_TYPES.include? activity[:payload_type]
          email_communication_parsed_activity = communications_activity_transformer(activity)
          next if email_communication_parsed_activity[:content].blank?
          append_timestamp(email_communication_parsed_activity, activity)
          parsed_activities.push(email_communication_parsed_activity)
				elsif ALERT_PAYLOAD_TYPES.include? activity[:action]
					result = alert_activity(activity)
					next if result.blank?
					append_timestamp(result, activity)
					parsed_activities.push(result)
				elsif activity[:actor][:type].to_i == USER_TYPE
					parsed_activity = {
						actor: {
							id: activity[:actor][:id].to_i,
							name: activity[:content][:actor_name]
						}
					}
					parsed_activity[:actor].merge!(original_id: activity[:actor][:original_user_id].to_i, original_name: activity[:actor][:original_user_name]) if activity[:actor][:original_user_id]
					action_words = activity[:action].split('_')
					operation = action_words.delete_at(-1)
					method_name = action_words.join('_')

					result = send(method_name,operation,activity)

					next if result[:content].blank?

					parsed_activity[:content] = result[:content]
					parsed_activity[:sub_contents] = result[:sub_contents] if result[:sub_contents]
					append_timestamp(parsed_activity, activity)
					parsed_activities.push(parsed_activity)
				else
					system_activity = parse_system_activity(activity)
					system_activity[:system_executed] = true if activity[:actor][:type].to_i != Va::Config::SCENARIO_AUTOMATION
					parsed_activities.push(system_activity)
				end
			}
		end

		append_start_token_to_parsed_activities(parsed_activities, start_token || nil)
		parsed_activities
	end

	def append_timestamp(parsed_activity, activity)
		current_user = User.current
		created_on = Time.at(activity[:timestamp] / (1000))
		parsed_activity[:timestamp] = created_on.utc
		parsed_activity[:created_at] = @params_obj[:api_v2] ? created_on.utc : formated_date(created_on.in_time_zone(current_user.time_zone), {include_year: true})
	end

	def parse_system_activity(activity)
		system_activity = {}

		system_changes = activity[:content][:system_changes][:changes]
		system_activity = {
			actor: {
				id: activity[:actor][:id].to_i,
				name: activity[:content][:actor_name]
			}
		}
		system_activity[:actor].merge!(original_id: activity[:actor][:original_user_id].to_i, original_name: activity[:actor][:original_user_name]) if activity[:actor][:original_user_id]
		current_user = User.current
		created_on = Time.at(activity[:timestamp] / (1000))
		system_activity[:created_at] = @params_obj[:api_v2] ? created_on.utc : formated_date(created_on.in_time_zone(current_user.time_zone), {include_year: true})
		if activity[:content][:system_changes][:id].to_i == -1
			rule_link = bold_tag(activity[:content][:system_changes][:name])
		else
			rule_link = generate_link({
				type: :rule,
				rule_type: activity[:actor][:type].to_i,
				id: activity[:content][:system_changes][:id],
				name: activity[:content][:system_changes][:name],
				workspace_id: activity.dig(:content, :system_changes, :workspace_id)
			})
		end
		rule_name = "(#{AUTOMATION_NAME_BY_TYPES[activity[:actor][:type].to_i]})"
		if [Va::Config::TICKET_WORKFLOW, Va::Config::PROBLEM_WORKFLOW, Va::Config::TASK_WORKFLOW, Va::Config::ALERT_WORKFLOW].include?(activity[:actor][:type].to_i)
			event_name = activity[:content][:system_changes][:properties][:current_event_name]
			content = " #{I18n.t('common_activities.system.workflow', rule_link: rule_link, automation: event_name)}"
		else
			content = " #{I18n.t('ticket_activities.system.va_rule', rule_link: rule_link, rule_name: rule_name)}"
		end
		if activity.dig(:content, :system_changes, :webhook_v2_properties).present?
			return generate_webhook_v2_activity(activity, system_activity, rule_link)
		end
		sub_contents = []
		default_contents = []
		custom_field_contents = []
		modified_custom_fields = []
		modified_default_fields = []
		sla_activity = {}
		system_changes.merge!(due_by_system_activities(activity))
		system_changes.each do |key, value|
			key = key.to_sym
			case key
				when :priority, :ticket_type, :status, :source, :category_name, :sub_category_name, :item_category_name, :department, :assigned_to_agent, :group, :impact, :urgency, :workspace_id, :workspace, :ticket_responders_from_workflow, :ticket_responders_workflow_failures
                    if :priority == key || :urgency == key || :impact == key || :status == key || :source == key
                        field_custom_label = Helpdesk::TicketField.customised_labels_for_default_fields[key]
												default_contents.push(I18n.t('ticket_activities.custom_field_name', content: system_changes[key][:name], field_name: field_custom_label) + sla_pause_by_status(system_changes, key))
				    elsif :category_name == key || :sub_category_name == key || :item_category_name == key
						# field_name = key.to_s.split("_")
						# field_name.pop
						default_contents.push(I18n.t("ticket_activities.#{key}", content: system_changes[key]))
					# sub_contents.push("Updated the priority as #{bold_tag(system_changes[key][:name])}")
					elsif :ticket_type == key
						default_contents.push(I18n.t("ticket_activities.type_name", content: system_changes[key]))
					elsif :department == key || :group == key
            valid_record = system_changes[key][:id] != 0
						field_name = (key == :department && msp_enabled?) ? :company : key
						args = { type: key, id: system_changes[key][:id].to_i, name: system_changes[key][:name] }
						args.merge!({workspace_id: system_changes[key][:workspace_id]}) if :group == key
						gen_link = valid_record ? generate_link(args) : bold_tag(system_changes[key][:name])
						default_contents.push(I18n.t("ticket_activities.#{field_name}_name", content: gen_link))
					elsif :ticket_responders_from_workflow == key
						ticket_responders = construct_tkt_responder_activity(system_changes["ticket_responders_from_workflow"])
						sub_contents << I18n.t("ticket_activities.ticket_responders_added", count: ticket_responders[:group].size, content: ticket_responders[:group].to_sentence) if ticket_responders[:group].size > 0
					elsif :ticket_responders_workflow_failures == key
						transformed_failures = transform_responders_workflow_failures(failures: system_changes["ticket_responders_workflow_failures"])
						transformed_failures.each do |failure|
							# content is required only in case of group ids not in case of responders limit getting exceeded or invalid group
							# [{:err_msg=>"ticket state is not valid", :content=>nil}]
							# [{:err_msg=>"they might not have an active schedule", :content=>["<a target='_blank' href='/groups/107'>Hardware Team</a>", "<a target='_blank' href='/groups/101'>Major Incident Team</a>"]}}
							sub_contents << I18n.t('automations.actions_list.assign_ticket_responders_error', content: failure[:content]&.to_sentence, err_msg: failure[:err_msg], count: failure[:content].length)
						end
					elsif :workspace == key
						default_contents.push(I18n.t('ticket_activities.custom_field_name', content: system_changes[key][:name], field_name: 'Workspace'))
					elsif  :assigned_to_agent == key
						valid_record = system_changes[key][:id] != 0
						gen_link = valid_record ? (generate_link({
								type: :user,
								id: system_changes[key][:id].to_i,
								name: system_changes[key][:name]
							})) : bold_tag(system_changes[key][:name])
						responder_content = I18n.t("ticket_activities.agent_name", content: gen_link)
							if system_changes[key][:failure_message].present?
								responder_content.concat(system_changes[key][:failure_message])
							elsif system_changes[key].key?(:auto_assign)
							  responder_content.concat(" #{I18n.t('ticket_activities.round_robin_agent_assign')}")
							end
							sub_contents.push(responder_content)
					elsif :workspace_id
						default_contents.push(I18n.t("common_activities.move_ticket_ws", { content: activity_changes[key].last }))
					end
				when :planned_start_date, :planned_end_date
					formatted_date = bold_tag(account_format_date_in_user_time_zone(value, { include_year: true }))
					sub_contents.push(I18n.t("ticket_activities.set_#{key}", content: bold_tag(formatted_date)))
				when :planned_effort
					sub_contents.push(I18n.t("ticket_activities.set_#{key}", content: bold_tag(value)))
				when :custom_fields
					custom_field_data = system_changes[key].each_with_object([]) do |custom_field, custom_field_values|
						if custom_field[:value].to_s == MODIFIED_FIELD
							modified_custom_fields << bold_tag(custom_field[:name])
						elsif custom_field[:value].is_a?(Array)
							operation_type = custom_field[:operation_type]
							if operation_type.present?
								val_changed = custom_field[:value].empty? ? NONE : custom_field[:value].to_sentence
								custom_field_values << I18n.t("ticket_activities.#{operation_type}_options", content: val_changed, field_name: custom_field[:name])
							else
								val_changed = custom_field[:value].empty? ? NONE : custom_field[:value].to_sentence
								custom_field_values << I18n.t('ticket_activities.custom_field_name', content: val_changed, field_name: custom_field[:name])
							end
						else
							value = transform_date_value(custom_field)
							custom_field_values << I18n.t('ticket_activities.custom_field_name', content: value, field_name: custom_field[:name])
						end
					end.to_sentence
					custom_field_contents.push(custom_field_data) unless custom_field_data.blank?
				when :add_tag
					bold_tag_names = system_changes[key].map { |tag_name| bold_tag(tag_name) }
					# title = bold_tag_names.size == 1 ? "Added tag" : "Added tags"
					# sub_contents.push("#{title} #{bold_tag_names.to_sentence}")
					sub_contents.push(I18n.t('ticket_activities.tags_added', count: bold_tag_names.size, content: bold_tag_names.to_sentence))
				when :remove_tag
					bold_tag_names = system_changes[key].map { |tag_name| bold_tag(tag_name) }
					sub_contents.push(I18n.t('ticket_activities.tags_removed', count: bold_tag_names.size, content: bold_tag_names.to_sentence))
				when :subject, :description
					modified_default_fields << bold_tag(key.to_s.titleize)
				when :add_a_cc
					bold_a_cc_emails = system_changes[key].map { |email| bold_tag(email) }
					sub_contents.push(I18n.t('ticket_activities.system.added_cc', count: bold_a_cc_emails.size, content: bold_a_cc_emails.to_sentence))
				when :add_task
					system_changes[key].each do |task|

						if !task[:success].nil? and !task[:success] and task[:failure_message]
							task_content = I18n.t('activities_log.task_addition_failure', title: task[:title], failure_message: task[:failure_message])
						else
							task_link = generate_link({
								:type => :task,
								:id => activity[:object][:id],
								:name => task[:title],
								:task_display_id => task[:display_id]
							})
							task[:workspace_id] = activity.dig(:content, :system_changes, :workspace_id)
							task_content_data = system_task(task)
							task_content = [I18n.t('activities_log.task_create', task: task_link, content: task_content_data[:content])]
							task_content.concat(task_content_data[:sub_content]) if task_content_data[:sub_content]
						end
						sub_contents.push(task_content)
						sub_contents.flatten!
					end
				when :update_task
					task = system_changes[key]
					task_link = generate_link({ type: :task, id: activity[:object][:id], name: task[:properties][:title], task_display_id: task[:properties][:display_id] })
					task_content_data = system_task(task)
					sub_contents.push(I18n.t('activities_log.task_update', task: task_link, content: task_content_data[:content]))
					sub_contents.concat(task_content_data[:sub_content]) if task_content_data[:sub_content]
				when :add_watcher
					populate_system_subscription_activity(sub_contents, system_changes, key)
				when :share_ticket_with
					populate_system_subscription_activity(sub_contents, system_changes, key, 'sharer')
			when :send_email_to
				# Group by action and show when cc, bcc flag is enabled
				# Ex: Sent Email cc : User1
				# Sent Email cc: User2 etc.
				if Account.current.er_wf_email_cc_bcc?
					system_changes[key].each.with_index(1) do |email_change, action_number|
						Workflow::BaseSendEmailTransformer.email_options.each do |email_type|
							email_data = email_type.eql?(:email_to) ? email_change : email_change.fetch(email_type, {})
							parse_send_email_activity(email_data, sub_contents, email_type)
						end
						sub_contents.push("") if action_number != system_changes[key].length # TODO: See if we have some helper method to add line break similar to bold, sentence etc.
					end
				else
					obj = send_email_options(:ticket, system_changes[key])
					parse_send_email_activity(obj, sub_contents, :email_to)
				end
				when :send_approval_mail
					approval_content = system_changes[key].each_with_object([]) do |approver, approver_link|
						approver_link.push(generate_link({
							type: :user,
							id: approver[:id].to_i,
							name: approver[:name]
						}))
					end.to_sentence
					sub_contents.push(I18n.t('change_activities.system_changes.send_approval_mail', members: approval_content))
				when :send_email_to_agent
					agent_content = []
					system_changes[key].each do |agent|
						agent_link = generate_link({
							type: :user,
							id: agent[:id],
							name: agent[:name]
						})
						agent_content << agent_link
					end
					sub_contents.push(I18n.t('common_activities.system_changes.send_email_to_agent', collection: agent_content.to_sentence))
				when :send_email_to_requester
					requester_content = []
					system_changes[key].each do |requester|
						requester_link = generate_link({
							type: :user,
							id: requester["id"].to_i,
							name: requester["name"]
						})
						requester_content << requester_link
					end
					sub_contents.push(I18n.t('common_activities.system_changes.send_email_to_requester', collection: requester_content.to_sentence))
				when :send_email_to_group
					group_content = []
					system_changes[key].each do |group|
						group_link = generate_link({
							type: :group,
							id: group["id"].to_i,
							name: group["name"]
						})
						group_content << group_link
					end
					sub_contents.push(I18n.t('common_activities.system_changes.send_email_to_group', collection: group_content.to_sentence))
				when :deleted
					sub_contents.push(I18n.t('ticket_activities.ticket_delete'))
				when :spam
					sub_contents.push(I18n.t('ticket_activities.flagged_spam'))
				when :skip_notification
					sub_contents.push(I18n.t('ticket_activities.system.skip_notification'))
				when :add_comment, :add_note
					system_changes[key].each do |activity_changes|
						type = I18n.t("ticket_activities.note.#{(activity_changes['private'].to_i == 0) ? 'public' : 'private'}")
						note_content = I18n.t('ticket_activities.note.added_note_type', note_type: type)
						if activity_changes.key?('to_emails')
							note_content << " #{I18n.t('ticket_activities.note.to_direct_emails', email_content: generate_emails_for_note(activity_changes, 'to_emails'))}"
						end
						sub_contents.push(note_content)
					end
					sub_contents
			when :trigger_webhook
					sub_contents.push(I18n.t('common_activities.system_changes.trigger_webhook'))
				when :workflow_approval_failed
					sub_contents.push(I18n.t('ticket_activities.system.approval_failure_log', member: value.first[:req_email]))
				when :fr_project_added
					data = system_changes[key].first
					fr_link = generate_link({
						type: :freshrelease,
						name: data[:name],
						url: data[:url]
					})
					sub_contents.push(I18n.t("freshrelease.project_create_success", act_on_type: data[:act_on_type], fr_link: fr_link))
				when :fr_project_generic_error
					sub_contents.push(I18n.t("freshrelease.project_create_generic_error", act_on_type: system_changes[key].first[:act_on_type]))
				when :fr_project_name_error
					data = system_changes[key].first
					sub_contents.push(I18n.t("freshrelease.project_create_name_error", act_on_type: data[:act_on_type], name: data[:name]))
				when :fr_project_template_not_found
					data = system_changes[key].first
					sub_contents.push(I18n.t("freshrelease.project_create_template_not_found_error", act_on_type: data[:act_on_type]))
				when :fr_issue_added
					data = system_changes[key].first
					fr_link = generate_link({
						type: :freshrelease,
						name: data[:name],
						url: data[:url]
					})
					sub_contents.push(I18n.t("freshrelease.task_create_success", act_on_type: data[:act_on_type], fr_link: fr_link))
				when :fr_issue_generic_error
					sub_contents.push(I18n.t("freshrelease.task_create_generic_error", act_on_type: system_changes[key].first[:act_on_type]))
				when :orchestration
					status = value[:status] ? "success" : "failure"
					sub_contents.push(I18n.t("ticket_activities.system.orchestration_#{status}", app_name: value[:app_name], app_action: value[:app_action]))
				when :webrequest, :timer
					status = value[:status] ? "success" : "failure"
          activity_key = "ticket_activities.system.#{key}_#{status}"
          node_name = formated_date(value[:node_name].in_time_zone(User.current.time_zone), {include_year: true}) if key == :timer
					(key == :timer) ? sub_contents.push(I18n.t(activity_key, node_name: node_name, reason: value[:reason])) : sub_contents.push(I18n.t(activity_key, node_name: value[:node_name]))
				when :expression
					sub_contents.concat(transform_exp_activities(value))
				when :sla_policy
					sla_activity_changes(sla_activity, system_changes, key)
				when :due_by
					if value.is_a?(Hash) && value.key?(:date_time)
						due_by_value = transform_date_value({value: value[:date_time], field_type: 'custom_date_time'})
						default_contents.push(I18n.t('ticket_activities.set_due_time', due_by: bold_tag(due_by_value)))
					else
						due_by_activities(sla_activity, system_changes, key)
					end
				else
			end
		end
		sub_contents.insert(0, I18n.t('ticket_activities.modified_custom_fields_titlize', content: modified_custom_fields.to_sentence)) unless modified_custom_fields.blank?
		sub_contents.insert(0, I18n.t('ticket_activities.modified_custom_fields_titlize', content: modified_default_fields.to_sentence)) if modified_default_fields.present?
		sub_contents.insert(0, custom_field_contents.to_sentence) unless custom_field_contents.blank?
		sub_contents.insert(0, default_contents.to_sentence) unless default_contents.blank?
		sla_activity.each { |_key, activity| sub_contents.push(activity) }
		if [Va::Config::TICKET_WORKFLOW, Va::Config::PROBLEM_WORKFLOW, Va::Config::TASK_WORKFLOW].include?(activity[:actor][:type].to_i)
			waiting_event_name = activity[:content][:system_changes][:properties][:waiting_event_names]
			if waiting_event_name.present?
				sub_contents.push(I18n.t('common_activities.system.workflow_waiting', name: waiting_event_name.join(",")))
			else
				sub_contents.push(I18n.t('common_activities.system.workflow_ends'))
			end
		end
		system_activity[:content] = content
		system_activity[:sub_contents] = sub_contents
		system_activity
	end

	def populate_responder_addition_activity(sub_contents, activity_changes, key)
		ticket_responders = construct_tkt_responder_activity(activity_changes[key][:added])
		sub_contents << I18n.t("ticket_activities.ticket_responders_added", count: ticket_responders[:group].size, content: ticket_responders[:group].to_sentence) if ticket_responders[:group].present?
		sub_contents << I18n.t("ticket_activities.ticket_individual_responders_added", count: ticket_responders[:user].size.size, content: ticket_responders[:user].to_sentence) if ticket_responders[:user].present?
	end

	def populate_responder_removal_activity(sub_contents, activity_changes, key)
		ticket_responders = construct_tkt_responder_activity(activity_changes[key][:removed])
		sub_contents << I18n.t("ticket_activities.ticket_responders_removed", count: ticket_responders[:group].size, content: ticket_responders[:group].to_sentence) if ticket_responders[:group].present?
		sub_contents << I18n.t("ticket_activities.ticket_individual_responders_removed", count: ticket_responders[:user].size, content: ticket_responders[:user].to_sentence) if ticket_responders[:user].present?
	end

	def ticket(operation,activity)
		sub_contents = []
		activity_changes = Hash(activity[:content][:changes])
		content = handle_ticket_create_content(activity_changes) if operation.to_sym == :create && !archived_operation?(activity)
		# content = "" if operation.to_sym == :update && activity_changes.keys.size == 1 && [:tags,:mark_spam,:split,:attached,:detached,:merged,:soft_delete,:deleted,:restore,:assets].include?(activity_changes.keys.first)
		content = '' if operation.to_sym == :create && activity_changes.keys == %w(attachments).freeze
		separator = ""
		result = {}
		default_fields = []
		custom_fields = []
		custom_text_fields = []
		modifield_default_fields = []
		sla_activity = {}
		if activity_changes.key?(:workspace_name) && Workspace.multi_workspace_mode?
			translation_string = operation.eql?('create') ? 'workspace_name' : 'move_ticket_ws'
			translation_string = 'move_ticket_ws_via_tool' if 'move_ticket_ws'.eql?(translation_string) && activity.dig('actor', 'triggered_from') == DataMigrationConstants::CENTRAL_EVENT_SOURCES[:migration_tools]
			default_fields << I18n.t("common_activities.#{translation_string}", { content: activity_changes[:workspace_name].last })
		end
		activity_changes.each do |key, value|
			key = key.to_sym
			case key
			    when :priority_name, :urgency_name, :impact_name
					ticket_customizable_field = TicketConstants.ticket_customizable_choices('agent_choices', key.to_s.split('_').first).detect { |choice| choice.last == activity_changes[key.to_s[0...-5]].last }.first
			    	default_field_label = Helpdesk::TicketField.customised_labels_for_default_fields[key.to_s.split('_').first.to_sym]
			    	default_fields << I18n.t("ticket_activities.custom_field_name", field_name: default_field_label, content: ticket_customizable_field)
				when :type_name, :category_name, :sub_category_name
					default_fields << I18n.t("ticket_activities.#{key}", content: activity_changes[key].last)
				when :source_name
					ticket_source = Account.current.translated_ticket_sources.detect { |c| c[:choice_id] == activity_changes[:source].last }
					source_name = ticket_source ? ticket_source[:name] : activity_changes[:source_name].last
					default_fields << I18n.t("ticket_activities.custom_field_name", field_name: Helpdesk::TicketField.customised_labels_for_default_fields[:source], content: source_name)
				when :status_name
					ticket_status = Account.current.ticket_status_values_from_cache.detect{|c| c.status_id==activity_changes[:status].last}
					status_name = ticket_status ? Helpdesk::TicketStatus.translate_status_name(ticket_status) : activity_changes[:status_name].last
					default_fields << I18n.t("ticket_activities.custom_field_name", field_name: Helpdesk::TicketField.customised_labels_for_default_fields[:status], content: status_name) + sla_pause_by_status(activity_changes, :status)
				when :item_category_name
					default_fields << I18n.t('ticket_activities.item_category_name', content: activity_changes[key].last)
				when :requested_for
					if !activity_changes.has_key?(:split) && operation.to_sym == :update
						requester_link = generate_link({
							type: :user,
							id: activity_changes[key][:id],
							name: activity_changes[key][:name]
						})
						default_fields << I18n.t('ticket_activities.requester', content: requester_link)
					end
				when :subject,:description
					modifield_default_fields << bold_tag(key.to_s.titleize)
				when :requested_for_name
					requester_link = generate_link({
						type: :user,
						id: activity_changes[:requested_for_id].last,
						name: activity_changes[key].last
					})
					default_fields << I18n.t('ticket_activities.requested_for_sr', content: requester_link)
				when :custom_fields
					custom_field_changes = activity_changes[:custom_fields]
					custom_field_changes.each do |custom_field_name, value|
						if custom_field_changes[custom_field_name].last.to_s == MODIFIED_FIELD
							custom_text_fields << bold_tag(custom_field_name.to_s)
						elsif value.first.is_a?(Array) || value.last.is_a?(Array)
							val_changed = value.last.blank? ? NONE : value.last.to_sentence
							custom_fields << I18n.t("ticket_activities.custom_field_name", field_name: custom_field_name.to_s, content: bold_tag(val_changed))
						else
							value =  custom_field_changes[custom_field_name].last.to_s
							value =  account_format_date_in_user_time_zone(value, {include_year: true}) if is_valid_date?(value)
							custom_fields << I18n.t("ticket_activities.custom_field_name", field_name: custom_field_name.to_s, content: value)
						end
					end
				when :department_name
					if activity_changes[key].last == NONE
						department_link = bold_tag(NONE)
					else
						if activity_changes[:department_id].last.to_i == -1
							department_link = bold_tag(activity_changes[key].last)
						else
							department_link = generate_link({
								type: :department,
								name: activity_changes[key].last,
								id: activity_changes[:department_id].last
							})
						end
					end
					title = msp_enabled? ? :company : :department
					default_fields << I18n.t("ticket_activities.#{title}_name", content: department_link)
				when :group_name
					if activity_changes[key].last == NONE
						group_link = bold_tag(NONE)
					else
						if activity_changes[:group_id].last.to_i == -1
							group_link = bold_tag(activity_changes[key].last)
						else
							group_link = generate_link({
								type: :group,
								name: activity_changes[key].last,
								id: activity_changes[:group_id].last,
								workspace_id: activity_changes[:group_workspace_id]
							})
						end
					end
					default_fields << I18n.t("ticket_activities.group_name", content: group_link)
				when :agent_name
					if activity_changes[key].last == NONE
						agent_link = bold_tag(NONE)
					else
						if activity_changes[:agent_id].last.to_i == -1
							agent_link = bold_tag(activity_changes[key].last)
						else
							agent_link = generate_link({
								type: :user,
								name: activity_changes[key].last,
								id: activity_changes[:agent_id].last
							})
						end
					end
					agent_assign_activity = I18n.t("ticket_activities.agent_name", content: agent_link)
					activity[:content][:system_changes] = activity[:content][:system_changes].first if activity[:content][:system_changes].present? && activity[:content][:system_changes].kind_of?(Array)
					(activity[:content][:system_changes].empty? || activity[:content].dig(:system_changes, :changes, :assigned_to_agent).nil?) ? (default_fields << agent_assign_activity) : (sub_contents << "#{I18n.t('audit_log.transformer.system')} #{agent_assign_activity} #{I18n.t('ticket_activities.round_robin_agent_assign')}")
				when :deleted
					sub_contents << I18n.t('ticket_activities.deleted')
				when :resolution_notes
					sub_contents << I18n.t('ticket_activities.resolution_notes_updated')
				when :is_archived
					value ? sub_contents << I18n.t('ticket_activities.archived') : sub_contents << I18n.t('ticket_activities.unarchived')
				when :mark_spam
					sub_contents << I18n.t('ticket_activities.flagged_spam')

				when :restore
					sub_contents << ((activity_changes[key] == "deleted") ? I18n.t('ticket_activities.restored_trash') : I18n.t('ticket_activities.restored_spam'))

				when :assets, :services
					asset_links = []
					if activity_changes[key].has_key?(:added)
						activity_changes[key][:added].each do |asset|
							if asset[:id.to_s].to_i == -1
								asset_links << bold_tag(asset[:name.to_s])
							else
								asset_links << generate_link({
									type: key.to_s.singularize.to_sym,
									name: asset["name"],
									id: asset["id"]
								})
							end
						end
						sub_contents << I18n.t("ticket_activities.#{key.to_s.singularize}_associate", content: asset_links.to_sentence)
					else
						if activity_changes[key][:removed][:id].to_i == -1
							asset_links << activity_changes[key][:removed][:name]
						else
							asset_links << generate_link({
								type: key.to_s.singularize.to_sym,
								name: activity_changes[key][:removed][:name],
								id: activity_changes[key][:removed][:id]
							})
						end
						sub_contents << I18n.t("ticket_activities.#{key.to_s.singularize}_dissociate", content: asset_links.join(','))
					end
				when :attachments
					sub_contents << populate_attachment_activity(value)
				when :manual_due_by
					due_by = bold_tag(account_format_date_in_user_time_zone(activity_changes[key].last, {:include_year => true}))
					sub_contents << I18n.t('ticket_activities.set_due_date', content: due_by)
				when :planned_start_date, :planned_end_date
					date = bold_tag(account_format_date_in_user_time_zone(activity_changes[key].last, { include_year: true }))
					default_fields << I18n.t("ticket_activities.set_#{key}", content: date)
				when :planned_effort
					default_fields << I18n.t("ticket_activities.set_#{key}", content: (activity_changes[key].last || I18n.t('none').downcase))
				when :watchers
					populate_subscription_activity(sub_contents, activity_changes, key)
				when :sharers
					populate_subscription_activity(sub_contents, activity_changes, key, 'sharer')
				when :ticket_responders
					populate_responder_addition_activity(sub_contents, activity_changes, key) if activity_changes[key].key?(:added) && activity_changes[key][:added].size > 0
					populate_responder_removal_activity(sub_contents, activity_changes, key) if activity_changes[key].key?(:removed) && activity_changes[key][:removed].size > 0
				when :tags
					if activity_changes[key].has_key?(:added)
						tag_names = []
						activity_changes[key][:added].each do |tag|
							tag_names << bold_tag(tag)
						end
						sub_contents << I18n.t("ticket_activities.tags_added", count: tag_names.size, content: tag_names.to_sentence)
					end
					if activity_changes[key].has_key?(:removed)
						tag_names = []
						activity_changes[key][:removed].each do |tag|
							tag_names << bold_tag(tag)
						end
						sub_contents << I18n.t("ticket_activities.tags_removed", count: tag_names.size, content: tag_names.to_sentence)
					end
				when :sla_policy
					sla_activity_changes(sla_activity, activity_changes, key)
				when :due_by
					due_by_activities(sla_activity, activity_changes, key)
				when :attached_association, :detached_association
					activity_changes[key].each do |attached_event|
						sub_contents << get_ticket_associated_activity(attached_event, key)
					end
				when :attached, :detached
					sub_contents << get_ticket_associated_activity(activity_changes[key], key)
				when :split
					unless activity_changes[key][:type].eql?("parent".freeze) && operation.to_sym == :create
						sub_contents << get_split_ticket_content(activity_changes)
					end
				when :fr_escalated
					activity.dig(:content, :system_changes, :fr_notification_triggered) ? sub_contents.push(I18n.t('ticket_activities.system.fr_escalation_triggered', sla_policy_link: generate_sla_policy_link(activity_changes))) : sub_contents.push(I18n.t('ticket_activities.system.fr_breached', sla_policy_link: generate_sla_policy_link(activity_changes)))
				when :is_escalated
					activity.dig(:content, :system_changes, :resolution_notification_triggered) ? sub_contents.push(I18n.t('ticket_activities.system.resolution_escalation_triggered', sla_policy_link: generate_sla_policy_link(activity_changes))) : sub_contents.push(I18n.t('ticket_activities.system.resolution_breached', sla_policy_link: generate_sla_policy_link(activity_changes)))
				when :merged
					ticket_links = []
					activity_changes[key][:tickets].each do |ticket|
						id = ticket[:id].to_i
						subject = ticket[:name]
						if id == -1
							link = ""
						else
							link = generate_link({
								id: id,
								name: subject,
								type: :ticket
							})
						end
						ticket_links << link
					end
					sub_contents << (activity_changes[key][:type].eql?("parent".freeze) ? I18n.t('ticket_activities.merged_from_parent', link: ticket_links) : \
            I18n.t('ticket_activities.merged_to_ticket', link: ticket_links))
				when :soft_delete
					sub_contents << I18n.t('ticket_activities.ticket_delete')
			end
		end

		if default_fields.present?
			content.blank? ? (content = (" #{default_fields.to_sentence}")) : content.concat(" #{default_fields.to_sentence}")
		end

		other_field = sub_contents.blank? ? nil : sub_contents.shift

		if other_field.present?
			if default_fields.blank? && custom_fields.blank? && custom_text_fields.blank?
				content.blank? ? content = " #{other_field}" : content.concat(" #{other_field}")
			else
				sub_contents.insert(0, ("#{other_field}"))
			end
		end

		if custom_text_fields.present?
			if default_fields.blank? && custom_fields.blank?
				content.blank? ? content = I18n.t('ticket_activities.modified_custom_fields', content: custom_text_fields.to_sentence) : content.concat(I18n.t('ticket_activities.modified_custom_fields', content: custom_text_fields.to_sentence))
			else
				sub_contents.insert(0, I18n.t('ticket_activities.modified_custom_fields_titlize', content: custom_text_fields.to_sentence))
			end
		end

		if custom_fields.present?
			default_fields.blank? ? (content.blank? ? (content = " #{custom_fields.to_sentence}") : content.concat(" #{custom_fields.to_sentence}")) : sub_contents.insert(0, custom_fields.to_sentence)
		end

		if modifield_default_fields.present?
			if default_fields.present?
				sub_contents.insert(0, I18n.t('ticket_activities.modified_custom_fields_titlize', content: modifield_default_fields.to_sentence))
			else
				text = " #{I18n.t('ticket_activities.modified_custom_fields', content: modifield_default_fields.to_sentence)}"
				content ||= ""
				content.concat(text)
			end
		end

		sla_due_date_activity = sla_activity[:sla_change]
		sla_due_date_activity = (sla_due_date_activity.blank? ? sla_activity[:due_date] : sla_due_date_activity.concat(" and #{sla_activity[:due_date]}")) if sla_activity[:due_date]
		sub_contents << "#{I18n.t('audit_log.transformer.system')} #{sla_due_date_activity}" if sla_due_date_activity
		bh_activity = sla_activity[:bh_change]
		sub_contents << "#{I18n.t('audit_log.transformer.system')} #{bh_activity}" if bh_activity.present?

		content = I18n.t('ticket_activities.ticket_update') if (sla_due_date_activity.present? || bh_activity.present?) && content.blank?

		if activity[:content][:tasks_dependency_type].present? && activity[:content][:tasks_dependency_mode].present?
			if activity[:content][:tasks_dependency_type].eql?(Itil::ItTaskDependency::DEPENDENCY_TYPES[:no_dependency])
				content = I18n.t('activities_log.task.no_dependency')
			else
				content = I18n.t('activities_log.task.finish_to_start_dependency')
				sub_contents  = activity[:content][:tasks_dependency_mode].eql?(Itil::ItTaskDependency::DEPENDENCY_MODES[:default_finish_to_start]) ? [I18n.t('activities_log.task.finish_to_start_default_mode')] : [I18n.t('activities_log.task.finish_to_start_completed_mode')]
			end
		end

		result[:content] = content
		result[:sub_contents] = sub_contents unless sub_contents.empty?
		result
  	end
  	alias_method :archived_ticket, :ticket

	def get_split_ticket_content activity_changes
		id = activity_changes[:split][:id].to_i
		subject = activity_changes[:split][:name]
		if id == -1
			ticket_link = ""
		else
			ticket_link = generate_link({
				id: id,
				name: subject,
				type: :ticket
			})
		end
		if activity_changes[:split][:type] == "parent".freeze
			requester_link = generate_requester_link(activity_changes) if activity_changes.has_key?(:requested_for)
			split_content = I18n.t('ticket_activities.split_ticket.has_split')
			unless requester_link.blank?
				split_content << " #{I18n.t('ticket_activities.for_requester', link: requester_link)}"
			end
			unless ticket_link.blank?
				split_content << " #{I18n.t('ticket_activities.split_ticket.from_ticket', ticket_link: ticket_link)}"
			end
		else
			if ticket_link.empty?
				split_content = I18n.t('ticket_activities.split_ticket.has_split')
			else
				split_content = I18n.t('ticket_activities.split_ticket.has_split_to', ticket_link: ticket_link)
			end
		end
		split_content
	end

	def handle_ticket_create_content activity_changes
		if activity_changes.has_key?(:split) && activity_changes[:split][:type] == "parent".freeze
			content = get_split_ticket_content(activity_changes)
		else
			content = I18n.t('ticket_activities.ticket_create')
			if activity_changes.has_key?(:requested_for)
				requester_link = generate_requester_link(activity_changes)
				content << I18n.t('ticket_activities.for_requester', link: requester_link)
				activity_changes.delete(:requested_for)
      end
			if activity_changes.has_key?(:requested_for_name)
				requester_link = generate_link({
					type: :user,
					id: activity_changes[:requested_for_id].last,
					name: activity_changes[:requested_for_name].last
				})
				(@params_obj[:private_api] && @params_obj[:api_v2]) ? content << "<br>#{I18n.t('ticket_activities.requested_for_sr', content: requester_link)}<br><br>" : content << ", #{I18n.t('ticket_activities.requested_for_sr', content: requester_link)},"
				activity_changes.delete(:requested_for_name)
			else
				content.concat(", ") if activity_changes.present?
			end
		end
		content
	end

	def generate_requester_link activity_changes
		requester_link = generate_link({
			type: :user,
			id: activity_changes[:requested_for][:id],
			name: activity_changes[:requested_for][:name]
		})
	end

	def construct_tkt_responder_activity(responder_groups)
		ticket_responders = { group: [], user: []}
		responder_groups.each do |responders |
			type = responders[:type] ? responders[:type].to_sym : :group
			link_type = (type == :group) ? :group : :user
			ticket_responders[type] ||= []
			ticket_responders[type] << generate_link({
				type: link_type,
				name: responders[:name],
				id: responders[:id]
			})
		end
		ticket_responders
	end

	def transform_responders_workflow_failures(failures:)
		failures.map do |failure|
			content = failure['groups'].empty? ? nil : construct_tkt_responder_activity(failure['groups'])
			{ err_msg: failure['err_msg'], content: content.present? ? content[:group] : content }
		end
	end

	def approval(operation, activity)
		activity_changes = activity[:content][:changes]
		if operation.to_sym == :create
			content = I18n.t('change_activities.approval.requested', link: get_approval_member_link(activity_changes)) if activity_changes.present? && activity_changes.key?(:member_id)
		elsif activity_changes.present?
			delegatee_content =  activity_changes.key?(:delegatee) ? I18n.t('change_activities.approval.delegatee') : ""
			member_changes = get_approval_member_link(activity_changes)
			activity_changes.each do |key, value|
				case key.to_sym
					when :remainder
						content = I18n.t('change_activities.approval.remainder', link: member_changes)
					when :state
						if activity_changes[key].last.downcase.eql?('approved'.freeze)
							content = I18n.t('change_activities.approval.approved', link: member_changes, delegatee: delegatee_content)
						elsif activity_changes[key].last.downcase.eql?('rejected'.freeze)
							content = I18n.t('change_activities.approval.rejected', link: member_changes, delegatee: delegatee_content)
						elsif activity_changes[key].last.downcase.eql?('requested'.freeze)
							content = I18n.t('change_activities.approval.requested', link: member_changes)
						elsif activity_changes[key].last.downcase.eql?('cancelled'.freeze)
							content = I18n.t('change_activities.approval.cancelled', link: member_changes)
						end
				end
			end
		end
		{content: content}
	end

	def task(operation, activity)
		operation = operation.to_sym
		activity_changes = activity[:content][:changes]
		dependency_type = activity.dig(:object, :tasks_dependency_type)
		finish_to_start_dependency = dependency_type.present? && dependency_type.to_i.eql?(Itil::ItTaskDependency::DEPENDENCY_TYPES[:finish_to_start])
		return if activity.dig(:content, :is_dependent_task)
		# in v1 of activities, we were sending task child_human_display_id as display_id
		display_id = activity[:content][:child_human_display_id] || activity[:content][:child_display_id]
		title_updated = false
		if activity_changes.present? && activity_changes.has_key?(:title)
			# title_changes = activity_changes.delete(:title)
			old_task_title = activity_changes[:title].first
			# only for genuine title update cases
			# for non title update / task create cases:
			# v1 passed title as ['*', 'new']. v2 passes it as [nil, 'new']
			if old_task_title != DONT_CARE_VALUE && old_task_title != nil
				title_updated = true
				old_task_link = generate_link({
					type: :task,
					id: activity[:object][:id],
					name: old_task_title,
					task_display_id: display_id
				})
			end
			task_title = activity_changes[:title].last
			task_link = generate_link({
				type: :task,
				id: activity[:object][:id],
				name: task_title,
				task_display_id: display_id
			})
		elsif activity[:content][:child_title]
			task_title = activity[:content][:child_title]
			task_link = generate_link({
				type: :task,
				id: activity[:object][:id],
				name: task_title,
				task_display_id: display_id
			})
		else
			task_link = ""
		end

		task_changes = []
		task_change_data = {}
		sub_contents = []
		task_sequencing_attributes = Set.new
		if !activity_changes.blank? && !(activity_changes[:deleted]&.last)
			# title_updated && operation.to_sym == :update ? content << ", " : content << " with "
			activity_changes.each do |key, value|
				#content << SEPARATOR + SPACE if match_found
				# match_found = true
				case key.to_sym
					when :status_name
						status_text = if activity_changes[:status]
														Task::Status.fetch_status_name_by_key(:ticket, activity_changes[:status].last.to_i)
													else
														Task::Status.translate_status_name(:ticket, activity_changes[:status_name].last)
						end
						task_changes << I18n.t('activities_log.task.status', status: status_text)
						task_sequencing_attributes << 'status'.pluralize if finish_to_start_dependency
					when :agent_id, :owner_id
						if activity_changes[key].last.to_i != 0
							agent_link = generate_link({
								type: :user,
								id: activity_changes[key].last,
								name: (activity_changes[:agent_name] || activity_changes[:owner_name]).last
							})
							task_changes << I18n.t('activities_log.task.owner_name', agent: agent_link)
						else
							task_changes << I18n.t('activities_log.task.owner_name', agent: 'none')
						end
					when :group_id
            if activity_changes[key].last.to_i != 0
  						group_link = generate_link({
  							type: :group,
  							id: activity_changes[key].last,
  							name: activity_changes[:group_name].last
  						})
  						task_changes << I18n.t('activities_log.task.group_name', group: group_link)
            else
              task_changes << I18n.t('activities_log.task.group_name', group: 'none')
            end
					when :due_date, :planned_start_date, :planned_end_date
						task_changes << I18n.t("activities_log.task.#{key}", { key.to_sym => account_format_date_in_user_time_zone(activity_changes[key].last, {include_year: true}) })
					when :notify_before
						task_changes << I18n.t('activities_log.task.notify_before', notify_before: Itil::ItTask::NOTIFY_NAMES_BY_KEY[activity_changes[key].last.to_i])
					when :title
						task_changes << I18n.t('activities_log.task.title', title: task_link) if operation == :update
					when :planned_effort
						task_changes << I18n.t("activities_log.task.planned_effort", { planned_effort: (activity_changes[key].last || I18n.t('none').downcase )})
					when :custom_fields
						next if activity_changes[:custom_fields].empty?
						sub_contents.insert(0, transform_task_custom_fields(activity_changes[:custom_fields]))
					when :ola_policy
						sub_contents << transform_ola_policy(activity_changes[:ola_policy])
					when :workspace_name
						task_changes << I18n.t("common_activities.workspace_name", { content: activity_changes[key].last }) if Workspace.multi_workspace_mode?
					when :stack_rank
						task_sequencing_attributes << 'stack_rank'
						task_sequencing_attributes << 'status'.pluralize if finish_to_start_dependency
						task_changes << I18n.t('activities_log.task.stack_rank_value', stack_rank: activity_changes[key].last)
				end
			end
			task_content = I18n.t('activities_log.task_content', content: task_changes.join(', ')) unless task_changes.empty?
			content = if operation == :create
          				I18n.t('activities_log.task_create', task: task_link, content: task_content)
          			elsif operation == :update && !(activity_changes && activity_changes[:deleted]&.last)
									contents = ''
									translation_key = 'activities_log.task_update'
									if activity_changes.key?(:workspace_name) && Workspace.multi_workspace_mode?
										translation_key = 'common_activities.move_task_ws_via_tool' if activity.dig('actor', 'triggered_from') == DataMigrationConstants::CENTRAL_EVENT_SOURCES[:migration_tools]
										workspace_name = activity_changes[:workspace_name].last
										if translation_key.include?('move_task_ws_via_tool') && task_content.include?("group as")
											contents = task_content.split(',').find { |str| str.include?("group as") }
											contents = contents.prepend("with ") unless contents.include?("with group")
										end
										contents = task_content if translation_key.include?('task_update')
									else
										contents = task_content
									end
									I18n.t(translation_key, task: (title_updated ? old_task_link : task_link), content: contents, workspace: workspace_name)
          			end
		elsif (operation == :update || operation == :delete) && activity_changes[:deleted]&.last
			task_human_display_id = display_id ? " (##{display_id})" : ""
			content = I18n.t('activities_log.task_delete', content: "#{task_title}#{task_human_display_id}")
			task_sequencing_attributes << 'stack_rank'
			task_sequencing_attributes << 'status'.pluralize if finish_to_start_dependency
		end

		if activity.dig(:content, :has_dependent_tasks)
			task_sequencing_attributes = task_sequencing_attributes.to_a
			task_sequencing_attributes.map! { |attribute| I18n.t("activities_log.task.#{attribute}") }
			sub_contents << I18n.t('activities_log.task.dependent_tasks_activities', {task_attributes: task_sequencing_attributes.join(' and ')}) if task_sequencing_attributes.present?
		end

		task_change_data[:content] = content
		task_change_data[:sub_contents] = sub_contents.flatten if sub_contents.any?
		task_change_data
	end

	def system_task(task)
		task_actions = []
		last_actions = []
		sub_contents = []
		system_task_data = {}
		task.each do |key, _value|
			case key.to_sym
			when :status
				# in case of task automator, task[key] is a Hash like {"id"=>"3", "name"=>"completed"}
				status_text = if task[:status].is_a?(Hash)
												Task::Status.fetch_status_name_by_key(:ticket, task[:status][:id].to_i)
											else
												Task::Status.translate_status_name(:ticket, task[:status])
				end
				task_actions << I18n.t('activities_log.task.status', status: status_text)
			when :due_date
				task_actions << I18n.t('activities_log.task.due_date', due_date: account_format_date_in_user_time_zone(task[key], {include_year: true}))
			when :planned_start_date, :planned_end_date
				formatted_date = account_format_date_in_user_time_zone(task[key], { include_year: true })
				task_actions << I18n.t("activities_log.task.#{key}", { key.to_sym => bold_tag(formatted_date) })
			when :planned_effort
				task_actions << I18n.t('activities_log.task.planned_effort', { planned_effort: bold_tag(task[key]) })
			when :notify_before
				task_actions << I18n.t('activities_log.task.notify_before', notify_before: Itil::ItTask::NOTIFY_NAMES_BY_KEY[task[key]])
			when :group
				valid_group = task[key][:id] != 0
				group_link = valid_group ? (generate_link({type: :group, id: task[key][:id], name: task[key][:name]})) : bold_tag(task[key][:name])
				task_actions << I18n.t('activities_log.task.group_name', group: group_link)
			when :assigned_to, :assigned_to_agent
				valid_agent = task[key][:id] != 0
				failure_message = task[key][:failure_message]
				agent_link = valid_agent ? (generate_link({type: :user, id: task[key][:id], name: task[key][:name]})) : task[key][:name]
				task_actions << I18n.t('activities_log.task.owner_name', agent: agent_link) + failure_message.to_s
			when :send_email_to_agent
				collection = task[key].map do |property|
					generate_link({ type: :user, id: property[:id], name: property[:name] })
				end
				last_actions << I18n.t("common_activities.system_changes.send_email_to_agent", { collection: collection.join(', ') })
      when :send_email_to_group
        collection = task[key].map do |property|
          generate_link({ type: :group, id: property[:id], name: property[:name] })
        end
        last_actions << I18n.t("common_activities.system_changes.send_email_to_group", { collection: collection.join(', ') })
			when :trigger_webhook
				last_actions << I18n.t('common_activities.system_changes.trigger_webhook')
			when :timer
				status = _value[:status] ? 'success' : 'failure'
        activity_key = "ticket_activities.system.timer_#{status}"
        node_name = formated_date(_value[:node_name].in_time_zone(User.current.time_zone), {include_year: true})
        task_actions << I18n.t(activity_key, node_name: node_name, reason: _value[:reason])
			when :custom_fields
				next if task[:custom_fields].empty?
				sub_contents.insert(0, transform_task_custom_fields(task[:custom_fields]))
			when :ola_policy
				sub_contents << transform_ola_policy(task[:ola_policy], true)
			when :workspace_id
				workspace_name = Workspace.find_by(display_id: _value).try(:name) if Workspace.multi_workspace_mode?
				task_actions << I18n.t("common_activities.workspace_name", { content: workspace_name }) if workspace_name.present?
			when :is_dependent_task
				sub_contents << I18n.t('activities_log.task.dependent_tasks_activities', {task_attributes: I18n.t('activities_log.task.statuses') }) if task[:is_dependent_task].eql?(false) && task[:has_dependent_tasks].eql?(true)
			when :stack_rank
				task_actions << I18n.t('activities_log.task.stack_rank_value', stack_rank: task[:stack_rank])
			else
			end
		end
		task_actions.concat(last_actions)
		system_task_data[:content] = I18n.t('activities_log.task_content', content: task_actions.to_sentence)
		system_task_data[:sub_content] = sub_contents.flatten if sub_contents.any?
		system_task_data
	end

	def timesheet(_operation, activity)
		transformed_data = {}
		transformed_objects = []
		transform_timesheets_content(activity, transformed_objects, transformed_data)
		transformed_data[:content] = transformed_objects.join(', ')
		transformed_data
	end

	def note(operation, activity)
		activity_changes = activity[:content][:changes]
		if operation == :delete.to_s || (activity_changes && activity_changes[:deleted]&.last)
			type = [Helpdesk::Note::CATEGORIES[:agent_private_response], 'true', true].include?(activity_changes[:private].last) ? I18n.t('ticket_activities.note.private') : I18n.t('ticket_activities.note.public')
			content = I18n.t('ticket_activities.note.delete', note_type: type)
		elsif activity_changes.has_key?(:type) && !activity_changes[:type].last.nil?
			note_action = activity_changes[:type].is_a?(Array) ?
					activity_changes[:type].last : activity_changes[:type]
				case note_action
					when "forward"
						content = "#{I18n.t('activities.forwarded')} "
					when "private_note_forward"
						content = "#{I18n.t('ticket_activities.private_note.forwarded')} "
					when "private_note_reply"
						content = "#{I18n.t('ticket_activities.private_note.replied')} "
					when "generate_document"
						content = "#{I18n.t('ticket_activities.note.document')} "
					when 'feedback'
						content = Account.current.csat_survey_serv? ? " #{I18n.t('ticket_activities.note.feedback')}" : " #{I18n.t('ticket_activities.note.added_note_type', note_type: I18n.t('ticket_activities.note.public'))}"
					else
						content = "#{I18n.t('ticket_activities.note.replied')} "
				end
		elsif activity_changes.has_key?(:private) && !activity_changes[:private].nil?
			case activity_changes[:private].last
				when Helpdesk::Note::CATEGORIES[:customer_response]
					content = " #{I18n.t('ticket_activities.note.added_note_type', note_type: I18n.t('ticket_activities.note.public'))}"
				when Helpdesk::Note::CATEGORIES[:agent_private_response]
					content = " #{I18n.t('ticket_activities.note.added_note_type', note_type: I18n.t('ticket_activities.note.private'))}"
				when Helpdesk::Note::CATEGORIES[:agent_public_response]
					content = " #{I18n.t('ticket_activities.note.added_note_type', note_type: I18n.t('ticket_activities.note.public'))}"
				when Helpdesk::Note::CATEGORIES[:third_party_response]
					content = " #{I18n.t('ticket_activities.note.added_note_type', note_type: I18n.t('ticket_activities.note.public'))}"
				when "true", true
					content = " #{I18n.t('ticket_activities.note.added_note_type', note_type: I18n.t('ticket_activities.note.private'))}"
				when "false", false
					content = " #{I18n.t('ticket_activities.note.added_note_type', note_type: I18n.t('ticket_activities.note.public'))}"
				else
					content = " #{I18n.t('ticket_activities.note.added')}"
			end
		end
		if activity_changes
			if activity_changes.key?(:to_emails)
				content << " #{I18n.t('ticket_activities.note.to_direct_emails', email_content: generate_emails_for_note(activity_changes, :to_emails))}"
			end
			if activity_changes.key?(:cc_emails)
				content << " #{I18n.t('ticket_activities.note.to_emails', action: :cc, email_content: generate_emails_for_note(activity_changes, :cc_emails))}"
			end
			if activity_changes.key?(:from_emails)
				content << " #{I18n.t('ticket_activities.note.from_email', email_content: generate_emails_for_note(activity_changes, :from_emails))}"
			end
			if activity_changes.key?(:bcc_emails)
				content << " #{I18n.t('ticket_activities.note.to_emails', action: :bcc, email_content: generate_emails_for_note(activity_changes, :bcc_emails))}"
			end
			if activity_changes.key?(:forward_emails)
				content << " #{I18n.t('ticket_activities.note.to_emails', action: :forward, email_content: generate_emails_for_note(activity_changes, :forward_emails))}"
			end
			if content.blank? && activity_changes.key?(:updated_at)
				content = I18n.t('common_activities.note.itil_note_update')
			end
		end
		{content: content}
	end

	def generate_emails_for_note activity_changes, key
		email_content = ""
		separator = ""
		activity_changes[key] =  activity_changes[key].last if (activity_changes[key].include? DONT_CARE_VALUE)
		activity_changes[key].each do |email|
			email = parse_email(email)[:email]
			email_content << "#{separator} #{bold_tag(email)}"
			separator = ","
		end
		email_content
	end

	def requested_item(operation, activity)
		return {} if activity[:content][:changes].blank? && operation.eql?('update')
		req_item_change_data = {}
		sub_contents = []
		operation = operation.to_sym
		activity_changes = activity[:content][:changes]
		item_name, can_translate, item_id = fetch_item_details(activity_changes, activity)
		content = get_content(operation, item_name)
		activity_changes.each do |property, changes|
			set_property_changes(property, changes, content, sub_contents)
		end
		sub_contents.insert(0, transform_requested_item_custom_fields(activity_changes[:custom_fields], item_id, can_translate )) if activity_changes && (activity_changes.dig(:custom_fields).present?)
		req_item_change_data[:content] = content
		req_item_change_data[:sub_contents] = sub_contents.flatten if sub_contents.any?
		req_item_change_data
	end

	def fetch_item_details(activity_changes, activity)
		item_name = get_item_name(activity_changes, activity)
		item_id = activity_changes[:service_item_id] if activity_changes

		return [item_name, false, item_id] unless item_id

		can_translate = can_translate?(activity_changes)

		if can_translate
			fetch_translations(item_id)
			can_translate = can_translate && @translations[item_id].translation_context.present?
			item_name = get_translated_item_name(item_id, item_name, can_translate)
		end

		[item_name, can_translate, item_id]
	end

	def get_item_name(activity_changes, activity)
		(activity_changes && activity_changes.key?(:name)) ? activity_changes[:name].last : activity[:content][:requested_item_name]
	end

	def can_translate?(activity_changes)
		translate = activity_changes[:translate]
		translate && Account.current.itsm_multilingual_support? && I18n.locale != Account.current.language.to_sym
	end

	def fetch_translations(item_id)
		@translations ||= {}
		@translations[item_id] ||= Catalog::Multilingual::EntityTranslation.new(item_id, 'Catalog::Item', I18n.locale)
	end

	def get_translated_item_name(item_id, item_name, can_translate)
		return item_name unless can_translate
		@translations[item_id].translated_name(item_name)
	end

	def get_content(operation, item_name)
		case operation
		when :create
			I18n.t('ticket_activities.requested_item.added', item_name: item_name)
		when :update
			I18n.t('ticket_activities.requested_item.updated', item_name: item_name)
		else
			I18n.t('ticket_activities.requested_item.deleted', item_name: item_name)
		end
	end

	def set_property_changes(property, changes, content, sub_contents)
		case property
		when 'stage_name'
			content << " #{I18n.t('ticket_activities.requested_item.stage_details', content: changes.last)}"
		when 'attachments'
			sub_contents << populate_attachment_activity(changes)
		end
	end

	def get_approval_member_link(activity_changes)
		generate_link ({
			type: :user,
			id: activity_changes[:member_id].last,
			name: activity_changes[:member_name].last
		})
	end

	# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
	def get_ticket_associated_activity(activity_changes, key)
		content = ""
		case activity_changes[:type]
			when "Minor_Ticket".freeze
			  id = activity_changes[:id].to_i
			  subject = activity_changes[:name]
			  if id == -1
			  	ticket_link = ""
			  else
			  	ticket_link = generate_link({
			  		type: :ticket,
			  		id: id,
			  		name: subject
			  	})
			  end
			  action_type = ( [:attached, :attached_association].include?(key) ? "added" : "removed")
			  content = I18n.t("ticket_activities.minor_ticket_#{action_type}", link: ticket_link)
			when "Major_Ticket".freeze
							id = activity_changes[:id].to_i
							subject = activity_changes[:name]
							if id == -1
								ticket_link = ""
							else
								ticket_link = generate_link({
									type: :ticket,
									id: id,
									name: subject
								})
							end
							action_type = ( [:attached, :attached_association].include?(key) ? "attached" : "detached")
							content = I18n.t("ticket_activities.major_ticket_#{action_type}", link: ticket_link)
			when "Itil::Problem".freeze
							id = activity_changes[:id].to_i
							if id == -1
								problem_link = ""
							else
								problem_link = generate_link({
									type: :problem,
									id: id,
									name: activity_changes[:name]
								})
							end
							action_type = ( [:attached, :attached_association].include?(key) ? "attached" : "detached")
							content = I18n.t("ticket_activities.module_#{action_type}", module_link: problem_link, associated_module: :problem)
			when "Itil::Change".freeze
							id = activity_changes[:id].to_i
							if id == -1
								change_link = ""
							else
								change_link = generate_link({
									type: :change,
									id: id,
									name: activity_changes[:name]
								})
							end
							action_type = ( [:attached, :attached_association].include?(key) ? "attached" : "detached")
							content = I18n.t("ticket_activities.module_#{action_type}", module_link: change_link, associated_module: :change)
			when "projects".freeze
				id = activity_changes[:id].to_i
				if id == -1
					project_link = bold_tag(activity_changes[:name])
				else
					project_link = generate_link({
						type: :project,
						id: id,
						name: activity_changes[:name]
					})
				end
				action_type = ( [:attached, :attached_association].include?(key) ? "attached" : "detached")
				content = I18n.t("ticket_activities.module_#{action_type}", module_link: project_link, associated_module: :project)
			when "freshrelease".freeze
				fr_item_link = generate_link({
					type: :freshrelease,
					name: CGI.escapeHTML(activity_changes[:name]),
					url: activity_changes[:url],
				})
				if [:attached, :attached_association].include?(key)
					content = ( activity_changes[:fr_item_type].eql?('issue') ? I18n.t('ticket_activities.associated_freshrelease_task', module_link: fr_item_link) :
						I18n.t('ticket_activities.associated_freshrelease_project', module_link: fr_item_link) )
				else
					content = ( activity_changes[:fr_item_type].eql?('issue') ? I18n.t('ticket_activities.dissociated_freshrelease_task', module_link: fr_item_link) :
						I18n.t('ticket_activities.dissociated_freshrelease_project', module_link: fr_item_link) )
				end
			when "Pom::PurchaseOrder".freeze
				id = activity_changes[:id].to_i
				if id == -1
					po_link = ""
				else
					po_link = generate_link({
											type: :purchase_order,
											id: id,
											po_number: activity_changes[:po_number],
											name: activity_changes[:name]
									})
				end
				action_type = ( [:attached, :attached_association].include?(key) ? "attached" : "detached")
				content = I18n.t("ticket_activities.module_#{action_type}", module_link: po_link, associated_module: "purchase order")
		end
		content
	end
	 # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def sla_activity_changes(sla_activity, activity_changes, key)
    if activity_changes[key].key?(:id)
      sla_policy_link = generate_link({
      type: :sla_policy,
      id: activity_changes[key][:id],
      name: activity_changes[key][:name],
      workspace_id: activity_changes.dig(key, :workspace_id)
      })
      sla_activity[:sla_change] = I18n.t('ticket_activities.sla_execution', sla_policy_link: sla_policy_link)
    end
    if activity_changes[key].key?(:bh_id)
      bh_link = generate_link({
      type: :business_hour,
      id: activity_changes[key][:bh_id],
      name: activity_changes[key][:bh_name],
      workspace_id: activity_changes.dig(key, :bh_workspace_id)
      })
      sla_activity[:bh_change] = I18n.t('ticket_activities.bh_execution', bh_link: bh_link)
    end
    sla_activity
  end

  def due_by_activities(sla_activity, activity_changes, key)
    due_by = bold_tag(account_format_date_in_user_time_zone(activity_changes[key].last, {include_year: true}))
		due_activity = [I18n.t('ticket_activities.set_due_time', due_by: due_by)]
		due_activity << I18n.t('ticket_activities.sla_stop_message') if activity_changes.key?(:sla_paused)
		sla_activity[:due_date] = due_activity.to_sentence(two_words_connector: ". ")
    sla_activity
  end

	def sla_pause_by_status(changes, key)
		(changes.key?(:sla_paused) && key == :status) ? I18n.t('ticket_activities.sla_pause_message') : ''
	end

  def due_by_system_activities(activity)
    return {} if activity[:content][:changes].blank?
    expected_keys = [:due_by, :sla_policy, :sla_paused]
    activity[:content][:changes].slice(*expected_keys)
  end

	def transform_requested_item_custom_fields(item_custom_fields, item_id, can_translate)
		item_custom_field_content = []
		modifed_field_names = []
		item_custom_fields.each do |field_name, field_changes|
			# older activities model changes custom fields hash structure - {“multi_drop”=> “First Choice, second”, “drop”=>“First Choice”}
			# new multilingual enabled activities model changes custom fields hash structure - {“multi_drop”=>{“label”=>“multi_drop”, “type”=>“custom_multi_select_dropdown”, “value”=>“second”}, “cf_drop”=>{“label”=>“drop”, “type”=>“custom_dropdown”, “value”=>“First Choice”}}
			# extract_field_data method is used to extract the label and values of the field from both the structures.
			field_label, field_value, field_type = extract_field_data(field_changes, field_name)
			field_label = can_translate ? get_translated_label(item_id, field_name, field_label) : CustomTranslate.label(field_label.to_s)
			if field_value.eql?(Enrichment::Constant::MODIFIED_FIELD)
				modifed_field_names << bold_tag(field_label)
			else
				field_value = process_field_value(item_id, field_name, field_value, field_type, can_translate)
				item_custom_field_content << I18n.t("ticket_activities.custom_field_name", { field_name: field_label, content:  field_value } )
			end
		end
		item_custom_field_content << I18n.t('ticket_activities.modified_custom_fields_titlize', content: modifed_field_names.to_sentence) if modifed_field_names.present?
		item_custom_field_content.to_sentence
	end

	def extract_field_data(field_changes, field_name)
		if field_changes.is_a?(Hash)
			[field_changes['label'], field_changes['value'], field_changes['type']]
		else
			[field_name, field_changes, nil]
		end
	end

	def process_field_value(item_id, field_name, field_value, field_type, can_translate)
		if is_valid_date?(field_value)
			account_format_date_in_user_time_zone(field_value, include_year: true)
		elsif can_translate && field_type && %w[custom_multi_select_dropdown custom_dropdown nested_field].include?(field_type)
			translate_requested_item_choices(item_id, field_name, field_value)
		else
			CustomTranslate.label(field_value)
		end
	end

	def get_translated_label(item_id, field_name, field_label)
		@translations[item_id].translated_label(field_name, field_label)
	end

	def translate_requested_item_choices(item_id, field_name, value)
		value.split(",").map { |ch_value| @translations[item_id].translated_choice(field_name, ch_value.strip) }.join(", ")
	end

  def archived_operation?(activity)
    activity[:action] == 'archived_ticket_create'
  end

  def parse_send_email_activity(obj, sub_contents, email_type)
		parse_cc_email(obj['cc_emails'], sub_contents, email_type)
		if obj['users'].present?
			contents = obj['users'].map do |agent|
				generate_link({ type: :user, id: agent[:id], name: agent[:name] })
			end.to_sentence
			sub_contents.push(I18n.t("common_activities.system_changes.send_#{email_type}", members: contents))
		end
		if obj['requester_groups'].present?
			req_groups = obj['requester_groups'].map { |req_groups| generate_link({ type: :requester_groups, id: req_groups[:id], name: req_groups[:name] }) }.join(', ')
			sub_contents.push(I18n.t("common_activities.system_changes.send_#{email_type}_rq_group", groups: req_groups))
		end
    if obj['agent_groups'].present?
      agent_groups = obj['agent_groups'].map { |group| generate_link({ type: :group, id: group[:id], name: group[:name], workspace_id: group[:workspace_id] }) }.join(', ')
			sub_contents.push(I18n.t("common_activities.system_changes.send_#{email_type}_ag_group", groups: agent_groups))
    end
		return if obj['external_emails'].blank?
		bold_emails = obj['external_emails'].map { |email| bold_tag(email) }
		sub_contents.push(I18n.t("common_activities.system_changes.send_#{email_type}", members: bold_emails.to_sentence ))
	end

  def parse_cc_email(cc_emails, sub_contents, email_type)
    return if cc_emails.blank?
    if cc_emails.is_a?(Hash)
      cc_emails.each do |key, value|
        bold_emails = value.map { |email| bold_tag(email) }
				sub_contents.push(I18n.t("common_activities.system_changes.#{key}_#{email_type}", members: bold_emails.to_sentence)) if bold_emails.present?
      end
    else
      bold_a_cc_emails = cc_emails.map { |email| bold_tag(email) }
			sub_contents.push(I18n.t("common_activities.system_changes.tkt_cc_#{email_type}", members: bold_a_cc_emails.to_sentence))
    end
	end

  private

	def generate_sla_link(sla_policy_id, sla_policy_name, workspace_id)
		generate_link({
      type: :sla_policy,
      id: sla_policy_id,
      name: sla_policy_name,
      workspace_id: workspace_id
    })
	end

  def generate_sla_policy_link(activity_changes)
		if activity_changes.key?(:sla_policy) && activity_changes[:sla_policy].key?(:id)
			generate_sla_link(activity_changes[:sla_policy][:id], activity_changes[:sla_policy][:name], activity_changes.dig(:sla_policy, :workspace_id))
		else
  		# During ticket activity export, Itil::ActivityExport job gets enqueued and the ticket object will not be received. Hence we need to load the ticket to find the linked SLA policy.
  		ticket = @params_obj[:object].is_a?(Helpdesk::Ticket) ? @params_obj[:object] : Account.current.tickets.find_by(display_id: @params_obj[:object_id])
			generate_sla_link(ticket.sla_policy.id, ticket.sla_policy.name, ticket.sla_policy.workspace_id)
		end
  end
end