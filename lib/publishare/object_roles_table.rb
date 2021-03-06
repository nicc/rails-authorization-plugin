require File.dirname(__FILE__) + '/exceptions'
require File.dirname(__FILE__) + '/identity'

module Authorization
  module ObjectRolesTable

    module UserExtensions
      def self.included( recipient )
        recipient.extend( ClassMethods )
      end

      module ClassMethods
        def acts_as_authorized_user(roles_relationship_opts = {})
          has_many :roles_users, roles_relationship_opts.merge(:dependent => :delete_all)
          has_many :roles, :through => :roles_users
          include Authorization::ObjectRolesTable::UserExtensions::InstanceMethods
          include Authorization::Identity::UserExtensions::InstanceMethods   # Provides all kinds of dynamic sugar via method_missing
        end
      end

      module InstanceMethods
        # If roles aren't explicitly defined in user class then check roles table
        def has_role?( role_name, authorizable_obj = nil )
          if authorizable_obj.nil?
            self.roles.find_by_name( role_name ) || self.roles.member?(get_role( role_name, authorizable_obj )) ? true : false    # If we ask a general role question, return true if any role is defined.
          else
            role = get_role( role_name, authorizable_obj )
            role ? self.roles.exists?( role.id ) : false
          end
        end

        def has_role( role_name, authorizable_obj = nil )
          role = get_role( role_name, authorizable_obj )
          if role.nil?
            if authorizable_obj.is_a? Class
              role = Role.create( :name => role_name, :authorizable_type => authorizable_obj.to_s )
            elsif authorizable_obj
              role = Role.create( :name => role_name, :authorizable => authorizable_obj )
            else
              role = Role.create( :name => role_name )
            end
          end
          self.roles << role if role and not self.roles.exists?( role.id )
        end

        def has_no_role( role_name, authorizable_obj = nil  )
          role = get_role( role_name, authorizable_obj )
          self.roles.delete( role ) if role
          delete_role_if_empty( role )
        end

        def has_roles_for?( authorizable_obj )
          if authorizable_obj.is_a? Class
            !self.roles.detect { |role| role.authorizable_type == authorizable_obj.to_s }.nil?
          elsif authorizable_obj
            !self.roles.detect { |role| role.authorizable_type == authorizable_obj.class.base_class.to_s && role.authorizable == authorizable_obj }.nil?
          else
            !self.roles.detect { |role| role.authorizable.nil? }.nil?
          end
        end
        alias :has_role_for? :has_roles_for?

        def roles_for( authorizable_obj )
          if authorizable_obj.is_a? Class
            self.roles.find(:all, :conditions => { :authorizable_type => authorizable_obj.to_s})
          elsif authorizable_obj
            self.roles.find(:all, :conditions => {
                              :authorizable_type => authorizable_obj.class.base_class.to_s, 
                              :authorizable_id => authorizable_obj.id })
          else
            self.roles.select { |role| role.authorizable.nil? }
          end
        end

        def has_no_roles_for(authorizable_obj = nil)
          old_roles = roles_for(authorizable_obj).dup
          self.roles.delete(old_roles)
          old_roles.each { |role| delete_role_if_empty( role ) }
        end

        def has_no_roles
          old_roles = self.roles.dup
          self.roles.clear
          old_roles.each { |role| delete_role_if_empty( role ) }
        end

        def authorizables_for( authorizable_class )
          unless authorizable_class.is_a? Class
            raise CannotGetAuthorizables, "Invalid argument: '#{authorizable_class}'. You must provide a class here."
          end
          begin
            authorizable_class.find(
              self.roles.find_all_by_authorizable_type(authorizable_class.base_class.to_s).map(&:authorizable_id).uniq
            )
          rescue ActiveRecord::RecordNotFound
            []
          end
        end

        private

        def get_role( role_name, authorizable_obj )
          if authorizable_obj.is_a? Class
            Role.find( :first,
                       :conditions => [ 'name = ? and authorizable_type = ? and authorizable_id IS NULL', role_name, authorizable_obj.to_s ] )
          elsif authorizable_obj
            Role.find( :first,
                       :conditions => [ 'name = ? and authorizable_type = ? and authorizable_id = ?',
                                        role_name, authorizable_obj.class.base_class.to_s, authorizable_obj.id ] )
          else
            Role.find( :first,
                       :conditions => [ 'name = ? and authorizable_type IS NULL and authorizable_id IS NULL', role_name ] )
          end
        end

        def delete_role_if_empty( role )
          role.destroy if role && role.users.count == 0
        end

      end
    end

    module ModelExtensions
      def self.included( recipient )
        recipient.extend( ClassMethods )
      end

      module ClassMethods
        def acts_as_authorizable
          has_many :accepted_roles, :as => :authorizable, :class_name => 'Role'

          has_many :users, :finder_sql => 'SELECT DISTINCT users.* FROM users INNER JOIN roles_users ON user_id = users.id INNER JOIN roles ON roles.id = role_id WHERE authorizable_type = \'#{self.class.base_class.to_s}\' AND authorizable_id = #{id}', :counter_sql => 'SELECT COUNT(DISTINCT users.id) FROM users INNER JOIN roles_users ON user_id = users.id INNER JOIN roles ON roles.id = role_id WHERE authorizable_type = \'#{self.class.base_class.to_s}\' AND authorizable_id = #{id}', :readonly => true

          before_destroy :remove_user_roles

          def accepts_role?( role_name, user )
            user.has_role? role_name, self
          end

          def accepts_role( role_name, user )
            user.has_role role_name, self
          end

          def accepts_no_role( role_name, user )
            user.has_no_role role_name, self
          end

          def accepts_roles_by?( user )
            user.has_roles_for? self
          end
          alias :accepts_role_by? :accepts_roles_by?

          def accepted_roles_by( user )
            user.roles_for self
          end

          def authorizables_by( user )
            user.authorizables_for self
          end
          
          # TODO:   refactor this into multiple, shorter methods
          def always_has( role, args = {} )
            raise ArgumentError, "role name must be a symbol" unless role.is_a? Symbol
            
            relationship = args.delete(:as) || role
            role_name = role.to_s
            
            association_reflection = self.reflect_on_association relationship
            raise NamedAssociationDoesNotExist unless association_reflection || !association_reflection.belongs_to?
            raise ArgumentError, "Invalid key" if args.size > 0
            
            before_save_method_name = "always_has_before_save_for_#{role_name}".to_sym
            after_save_method_name = "always_has_after_save_for_#{role_name}".to_sym
            
            define_method before_save_method_name do
              #  ok this is a little weird.  I need the old associated record to remove the role from it.
              #  So I redo a find on this object id and traverse the association, removing the role for it
              #  before saving the actual record (self).  Obv dont do this if it's a new record.
              #  It's also optimised to save the old and new associated records as instance vars on the new one, 
              #  and only redoes the roles if they differ.  The after_save then also has access to the instance vars.
              
              #  This is outside the unless so that nil == nil isn't a problem when deciding whether to update roles.
              instance_variable_set "@new_#{role_name}_instance".to_sym, self.send(relationship)
              
              unless self.new_record?
                instance_variable_set "@old_#{role_name}_instance".to_sym, self.class.find(self.id, :include => relationship).send(relationship)
                
                old_association = instance_variable_get("@old_#{role_name}_instance".to_sym)
                new_association = instance_variable_get("@new_#{role_name}_instance".to_sym)
                
                self.accepts_no_role role_name, old_association unless new_association == old_association
              end
            end
            
            define_method after_save_method_name do
              old_association = instance_variable_get("@old_#{role_name}_instance".to_sym)
              new_association = instance_variable_get("@new_#{role_name}_instance".to_sym)
              
              self.accepts_role role_name, new_association unless new_association == old_association
            end
            
            before_save before_save_method_name
            after_save after_save_method_name
          end

          include Authorization::ObjectRolesTable::ModelExtensions::InstanceMethods
          include Authorization::Identity::ModelExtensions::InstanceMethods   # Provides all kinds of dynamic sugar via method_missing
        end
      end

      module InstanceMethods
        # If roles aren't overriden in model then check roles table
        def accepts_role?( role_name, user )
          user.has_role? role_name, self
        end

        def accepts_role( role_name, user )
          user.has_role role_name, self
        end

        def accepts_no_role( role_name, user )
          user.has_no_role role_name, self
        end

        def accepts_roles_by?( user )
          user.has_roles_for? self
        end
        alias :accepts_role_by? :accepts_roles_by?

        def accepted_roles_by( user )
          user.roles_for self
        end

        private

        def remove_user_roles
          self.accepted_roles.each do |role|
            role.roles_users.delete_all
            role.destroy
          end
        end

      end
    end

  end
end

