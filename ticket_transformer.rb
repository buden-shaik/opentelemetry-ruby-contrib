 1
<% datetime_format = current_account.date_type(:short_day_with_time); 2
if approval.present? && approval.approval_status == Itil::Approval::APPROVAL_KEYS_BY_TOKEN[:peer_responded]; 3
approvalType = Itil::Approval::APPROVAL_TYPE_NAMES_BY_KEY[approval.approval_type].to_sym; 4
if first_responder.present? && first_responder.approval_status.present?; 5
firstResponderApprovalStatus = Itil::Approval::APPROVAL_NAMES_BY_KEY[first_responder.approval_status].to_sym; 6
approvalStatus = firstResponderApprovalStatus.eql?(:approved) ? (approvalType.eql?(:majority) ? 'approved_by_majority' : 'already_approved') : (approvalType.eql?(:majority) ? 'rejected_by_majority' : 'already_rejected'); 7
end; 8
end %> 