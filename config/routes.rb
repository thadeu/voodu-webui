Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "dashboard#index"

  # Pods — index + per-name restart action.
  # Container names contain dots ("clowk-web.a3f9") so we relax the
  # path constraint that would otherwise treat the trailing token
  # as a format extension.
  get  "/pods", to: "pods#index"
  post "/pods/:name/restart", to: "pods#restart", as: :restart_pod, constraints: { name: %r{[^/]+} }

  # Logs — index (pod picker) + per-pod tail. Same constraint.
  get "/logs", to: "logs#index"
  get "/logs/:name", to: "logs#show", as: :pod_logs, constraints: { name: %r{[^/]+} }

  get "/metrics",  to: "metrics#index"
  get "/settings", to: "settings#index"

  resources :islands, only: [:index, :new, :create, :show, :destroy] do
    member do
      post :select
    end
  end

  get "/styleguide", to: "styleguide#index"
end
