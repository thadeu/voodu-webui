class CreateIslands < ActiveRecord::Migration[8.1]
  def change
    create_table :islands do |t|
      # Operator-supplied display label. Shows in the sidebar list.
      t.string :name, null: false

      # Full URL of the voodu controller's PAT plane.
      # Example: http://203.0.113.10:8687
      t.string :endpoint, null: false

      # The PAT itself, encrypted at rest by Rails' built-in
      # `encrypts :pat` (ActiveRecord Encryption). Stored as a single
      # opaque blob; we never query by it.
      t.text :pat_ciphertext, null: false

      t.timestamps
    end

    add_index :islands, :name, unique: true
  end
end
