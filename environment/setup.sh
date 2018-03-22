set -e
gcloud config set component_manager/disable_update_check true
(cd "$(dirname "$0")"
# only do the setup if it has not already been done
if [ ! ~/.firecloud-env.config ]; then
    #TODO: if they have multiple identities ask if they are using the right one
    #Check if gcloud is installed 
    if gcloud version | grep -q "gcloud: command not found"; then
        echo
        echo "You do not have Google Cloud SDK installed, which you need to run this script."
        while read -p "Do you want to install gcloud SDK? (yes or no) " yn; do
            #install gcloud, or not
            case $yn in
                [Yy]* ) 
                    curl https://sdk.cloud.google.com | bash
                    exec -l $SHELL
                    gcloud init
                    break;;

                [Nn]* )
                    echo "Exiting."
                    exit 1 
                    break;;

                * ) echo "Please answer yes or no.";;
            #install gcloud, or not
            esac 
        done                                  
    fi
    echo
    while read -p "Do you have an existing Google project where you want to run workflows? (yes or no) " yn; do
        #Which Google project to use (new or existing) 
        case $yn in
            [Yy]* ) read -p "Enter your project name: " project; break;;
            [Nn]* ) 
                echo
                echo "If you do not have a project you want to use, a new one will be generated for you."
                while read -p "Would you like to continue? (yes or no) " yn; do
                    #Continue and create new project, or not
                    case $yn in
                       [Yy]* )
                            
                            echo
                            echo
                            echo "You have access to the following billing accounts."
                            echo "--------------------------------------------------------------------------------"
                            gcloud alpha billing accounts list
                            accounts=$(gcloud alpha billing accounts list 2>&1)
                            if echo $accounts | grep -q "Listed 0 items"; then 
                                echo
                                echo "You do not have a Google billing account setup.  In order to run "
                                echo "WDLs in the Google cloud you need an account to bill to.  See the README "
                                echo "for more details."
                                echo "To learn about creating a billing account, see here: "
                                echo "https://cloud.google.com/billing/docs/how-to/manage-billing-account#create_a_new_billing_account"
                                exit 1
                            fi
                            
                            echo 
                            echo
                            echo "Enter the billing account ID to use for this project" 
                            read -p "    (IDs will look similar to this: 002481-B7351F-CD111E):" account
                            #gcloud projects create
                            project="fc-env-$(date +%H-%M-%S)-$(gcloud config get-value account | sed 's/@.*//')"
                            echo
                            gcloud projects create $project
                            echo
                            echo "Linking project to your billing account..."
                            echo
                            gcloud alpha billing accounts projects link $project --billing-account=$account
                            sleep 10s
                            echo
                            echo "Project created and can be viewed at: https://console.cloud.google.com/home/dashboard?project=$project"
                            echo
                            break;;                        
                            
                       [Nn]* ) 
                            echo "Exiting."
                            exit 1 
                            break;;

                        * ) echo "Please answer yes or no.";;

                    #Continue and create new project, or not
                    esac 

                done

                break;;
            
            * ) echo "Please answer yes or no.";;
    
        #Which Google project to use (new or existing)
        esac 
    done 
    
    #create bucket
    bucket=$project-executions
    echo
    echo "gs://$bucket"
    echo
    gsutil mb -p $project gs://$bucket
    echo
    echo "Bucket created for Cromwell execution outputs can be viewed at: https://console.cloud.google.com/storage/browser/$bucket"
    echo
    #TODO: ask for dockerhub credentials if they are going to use private dockers

    #Create config
    echo "include required(classpath(\"application\"))

google {

  application-name = \"cromwell\"

  auths = [
    {
      name = \"application-default\"
      scheme = \"application_default\"
    }
  ]
}

engine {
  filesystems {
    gcs {
      auth = \"application-default\"
    }
  }
}

backend {
  default = \"JES\"
  providers {
    JES {
      actor-factory = \"cromwell.backend.impl.jes.JesBackendLifecycleActorFactory\"
      config {
        // Google project
        project = \"$project\"
        compute-service-account = \"default\"

        // Base bucket for workflow executions
        root = \"gs://$bucket\"

        // Polling for completion backs-off gradually for slower-running jobs.
        // This is the maximum polling interval (in seconds):
        maximum-polling-interval = 600

        // Optional Dockerhub Credentials. Can be used to access private docker images.
        dockerhub {
          // account = \"\"
          // token = \"\"
        }

        genomics {
          // A reference to an auth defined in the \`google\` stanza at the top.  This auth is used to create
          // Pipelines and manipulate auth JSONs.
          auth = \"application-default\"
          // Endpoint for APIs, no reason to change this unless directed by Google.
          endpoint-url = \"https://genomics.googleapis.com/\"
        }

        filesystems {
          gcs {
            // A reference to a potentially different auth for manipulating files via engine functions.
            auth = \"application-default\"
          }
        }
      }
    }
  }
}   " > firecloud-env.config
    echo
    echo "Your configuration file is ready! It is stored in firecloud-env.config."
    echo
    echo "To use this configuration you will need to enable the following APIs:"
    echo "Google Cloud Storage, Google Compute Engine, Google Genomics."
    while read -p "Would you like to enable these APIs now? (yes or no)" yn; do
        #enable APIs, or not
        case $yn in
            [Yy]* ) 
                gcloud --project $project services enable compute.googleapis.com genomics.googleapis.com storage-component.googleapis.com
                break;;

            [Nn]* )
                echo "Don't forget to enable the APIs through the Google Console or gcloud SDK prior to using the configuration."
                echo "Exiting."
                exit 1 
                break;;

            * ) echo "Please answer yes or no.";;
        #enable APIs, or not
        esac 
    done
    echo
    while read -p "Do you want to run a Hello WDL test to check your configuration? (yes or no)" yn; do
        test_configuration="java -Dconfig.file=firecloud-env.config -jar cromwell.jar run hello.wdl -i hello.inputs"
        #Test configuration
        case $yn in
            [Yy]* ) 
                #create WDL
                echo "task hello {
  String addressee  
  command {
    echo \"Hello \${addressee}! Welcome to Cromwell . . . on Google Cloud!\"  
  }
  output {
    String message = read_string(stdout())
  }
  runtime {
    docker: \"ubuntu:latest\"
  }
}

workflow wf_hello {
  call hello

  output {
     hello.message
  }
}
" > hello.wdl

                #create inputs
                echo "{
  \"wf_hello.hello.addressee\": \"World\"
}
" > hello.inputs

                cromwell=$(curl -i https://api.github.com/repos/broadinstitute/cromwell/releases/latest | grep browser_download_url | grep -e "/cromwell-" | sed 's/"browser_download_url": "//; s/ //g; s/"//')

                if [[ $cromwell != https://github.com/broadinstitute/cromwell/releases/download/* ]]; then
                    echo
                    echo "We cannot find the latest version of Cromwell to download."
                    echo "Visit https://github.com/broadinstitue/cromwell/releases to download the latest version"
                    echo "to this directory. Then run $ $test_configuration"
                    echo 
                    echo "Exiting."
                    exit 1
                fi

                #Download that version
                curl -L $cromwell --output cromwell.jar
                echo
                echo "Cromwell is downloaded and ready for operation."
                echo
                break;;

            [Nn]* )
                echo "Exiting."
                exit 1 
                break;;

            * ) echo "Please answer yes or no.";;
        #Test configuration
        esac 
    done
    echo
    echo "Starting Hello World test."
    echo
    echo "Running $ $test_configuration"
    echo
    #Test setup
    bash -c "$test_configuration"    
    echo
    echo "Workflow succeeded!"
    echo "Outputs for this workflow can be found in gs://$bucket"
    echo
    echo "Now run the cromwell.sh script to automatically use "

else
    echo "Setup has already been done.  If you would like to clear this setup and create"
    echo "a new one, you can remove the file ~/.firecloud-env.config"
fi) && gcloud config set component_manager/disable_update_check false