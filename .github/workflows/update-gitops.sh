      - name: Deploy to GitOps
        run: ./ton-script.sh
        env:
          GITOPS_PAT: ${{ secrets.GITOPS_PAT }}
          APP_NAME: ${{ github.event.repository.name }}
          SHA: ${{ github.sha }}
          ENV: production
          INGRESS_DOMAIN: ${{ vars.INGRESS_DOMAIN }}
