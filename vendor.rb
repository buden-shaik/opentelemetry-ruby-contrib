class Itil::Vendor < ApplicationRecord

	self.table_name = "itil_vendors"

	include LookupFields::ActsAs::Datasource
	include Helpdesk::ToggleEmailNotification
	include Search::ElasticSearchIndex
	include Itil::SaveModelChanges
	include Concerns::CentralService
	include Concerns::SandboxConcern
	include Concerns::ApiNameGenerator
	include Concerns::ConfigurationConcern
  include Concerns::Esv2CentralSync

	belongs_to_account
	concerned_with :central_v2_methods
  xss_sanitize only: [:name, :description, :contact_name, :email, :phone, :mobile], plain_sanitizer: [:name, :description, :contact_name, :email, :phone, :mobile]
	before_destroy :check_for_assoc_ci, :check_for_contract, :check_for_purchase_orders # placed it here because the sql transactions of deleting product_vendors should happen after this validation
	before_save :store_model_changes
	has_fields flexifield_classes: ['Itil::VendorFieldData','Itil::VendorTextFieldData'], form_id: 'vendor_form_id'

	has_many :product_vendors, :class_name => "Itil::ProductVendor", :dependent => :delete_all
	has_many :products, :class_name => "Itil::Product", :through => :product_vendors
	has_many :contracts, :class_name => "Cmdb::Contract"

	has_one :address, :class_name => 'Address', :as => 'addressable', :dependent => :destroy
	has_many :cmdb_applications, class_name: "Cmdb::Application", foreign_key: :manufacturer_id
	has_many :purchase_orders, class_name: "Pom::PurchaseOrder", foreign_key: :vendor_id, dependent: :nullify

	handle_record_not_unique(index: "index_itil_vendors_on_account_id_name", message: { name: :taken })
	validates_presence_of :name
	after_save :add_product_vendor, :if => :product_vendor

	after_update :update_es_doc, if: :saved_change_to_name?

	attr_accessor :product_vendor, :from_discovery, :skip_mandatory_field_check
  alias_attribute :primary_contact, :contact_name
	alias_attribute :configuration_label, :name

	after_commit ->(obj) { obj.send_to_esv2 }, on: [:update, :create]
	after_commit ->(obj) { obj.send_to_esv2_worker("destroy") }, on: :destroy
	after_commit :nullify_dependent, on: :destroy

	delegate :primary_contact_name, :first_name, :zip, :address1, :address2, :country, :state, :city,  to: :address, allow_nil: true
	central_publishable central_target: :vendor, blueprint: Cmdb::VendorBlueprint
	handle_sandbox_operation
	populate_api_name api_name_generator: ->(instance) { api_name_formator(instance.name) }
	acts_as_datasource es_template: :name_auto_complete

	def add_product_vendor
		@product_vendor = self.product_vendors.new(product_vendor)
		@product_vendor.save
	end

	def address_attributes=(addr_attributes)
		unless self.address
			self.build_address(addr_attributes)
		else
			self.address.update_attributes(addr_attributes)
		end
	end

	def check_for_assoc_ci
		ref_ids = [Cmdb::CmdbConstants::CI_TYPES[:hardware], Cmdb::CmdbConstants::CI_TYPES[:software], Cmdb::CmdbConstants::CI_TYPES[:consumable]]
		ci = account.ci_level_0_fields.where(ActiveRecord::Base.send(:sanitize_sql_array, ["roots_ref_id in (?) and #{Cmdb::CiLevel_0Field.vendor_field.to_s} = ?", ref_ids, self.id])).first
		if ci
			errors.add(:base, I18n.t(Asset::CITypeToAssetType.ci_type_to_asset_type('itil.vendor.delete_issue'), vendor_name: name))
			throw(:abort)
		end
	end

	def check_for_contract
		unless contracts.empty?
			errors.add(:base, I18n.t('itil.vendor.delete_contract_error', vendor_name: name))
			throw(:abort)
		end
	end

  def check_for_purchase_orders
  	unless purchase_orders.empty?
    	errors.add(:base, I18n.t('itil.vendor.delete_purchase_order_error', vendor_name: name))
 			throw(:abort)
		end
  end

	def set_flexifield_form_id
    	flexifield.form_id = @custom_form.id
  	end

  	def custom_form
    	@custom_form ||= account.vendor_form
  	end

  	def custom_field_aliases
    	@custom_field_aliases ||= begin
      		custom_form.custom_fields.map(&:name)
    	end
  	end

    def custom_fields
      dropdown_field_names = custom_form.custom_dropdown_fields.map { |f| [f.name, f.choices.map { |f| [f.id, f.value] }.to_h] }.to_h
      custom_field.each_with_object({}) do |(k, v), hash|
        v = dropdown_field_names[k][v.to_s] if dropdown_field_names.key?(k)
        hash[k[3..-1]] = v
      end
    end

  def im_custom_field
    dropdown_field_names = custom_form.custom_dropdown_fields.map { |f| [f.name, f.choices.map { |f| [f.id, f.internal_name] }.to_h] }.to_h
    custom_field.each_with_object({}) do |(field_name, val), hash|
      value = dropdown_field_names.key?(field_name) ? dropdown_field_names[field_name][val.to_s] : val
      hash[field_name] = value
    end
  end

  # Sandbox Sync related callbacks starts here
  def trigger_sb_post_create_callbacks
  	@custom_form = (account.vendor_form || Itil::VendorForm.find_by(account_id: Account.current.id)) if Thread.current[:account_clone]
    send_to_esv2
  end

  def trigger_sb_post_update_callbacks
  	update_es_doc if saved_change_to_name?
    send_to_esv2
  end

  def trigger_sb_post_delete_callbacks
    trigger_sb_central_changes
    send_to_esv2_worker('destroy')
  end

  def trigger_sb_central_changes
    collect_model_changes_v2
    push_to_central_v2
  end
 # Sandbox Sync related callbacks ends here

	def to_esv2_json
		as_json(root: false, tailored_json: true, only: [:account_id, :name, :created_at, :updated_at, :vendor_type]).to_json
	end

  def self.translated_key(key)
    I18n.t("#{LookupFields::Constants::I18N_PREFIX_DS}#{key}")
  end

	def self.search(account_id, search_string, page, status_filter, uuid = nil, per_page)
		per_page = per_page ? per_page.to_i : 100
		page = page ? page.to_i : 1
		exact_match = SearchUtil.es_exact_match?(search_string)
		search_term = exact_match ? SearchUtil.es_filter_exact(search_string) : search_string
		params = {
				search_term: search_term,
				account_id: account_id,
				request_id: uuid || UUIDTools::UUID.timestamp_create.hexdigest,
				size: per_page,
				offset: per_page * (page.to_i - 1),
				sort_by: "created_at",
				sort_direction: "desc",
				from: per_page * (page.to_i - 1)
		}
		results = Search::V2::QueryHandler.new({
																		 account_id:   account_id,
																		 context:      "name_auto_complete",
																		 exact_match:  exact_match,
																		 es_models:    { "vendor" => { model: "Itil::Vendor" } },
																		 current_page: page,
																		 offset:       per_page * (page.to_i - 1),
																		 types:        ["vendor"],
																		 es_params:    params
																 }).query_results
		results.empty? ? Itil::Vendor.where(["name LIKE (?) ", "#{search_term}%"]) : results
	end

  def collect_properties_v2(options = {})
    params = super(options)
    # added for auditlog global filter in workspaces
    params[:central_properties][:workspace_filter] ||= Workspace::GLOBAL_WORKSPACE_DISPLAY_ID
    params
  end

	private

	  def update_es_doc
		SidekiqWorker.enqueue(UpdateAssociatedEsDocs, {base_class_name: self.class.name, base_object_id: id, associations: [:cmdb_applications]}) if cmdb_applications.exists?
			SidekiqWorker.enqueue(UpdateAssociatedEsDocs, {base_class_name: self.class.name, base_object_id: id, associations: [:purchase_orders]}) if !purchase_orders.empty?
		end

    def nullify_dependent
      account.cmdb_applications.update_all_in_batches({ manufacturer_id: nil }, { manufacturer_id: id }, { exec_method_name: { push_to_central_v2: nil }})
    end

  def validate_required_fields?
    skip_mandatory_field_check ? false : super
  end

  def config_module_type
    :VendorConfiguration
  end

  def push_to_central_v2?
    !update_with_empty_changes?
  end

  def update_with_empty_changes?
    central_v2_operation.eql?(:update) && @central_changes.blank?
  end

  def check_model_changes?
    true
  end
end